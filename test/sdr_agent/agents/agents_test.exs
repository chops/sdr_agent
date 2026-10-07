defmodule SdrAgent.AgentsTest do
  @moduledoc false
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      kernel: system_actor(:kernel, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  describe "AgentDefinition" do
    test "registers a hashed definition once and audits it", ctx do
      definition = AgentsFixtures.definition!(ctx.tenant)
      again = AgentsFixtures.definition!(ctx.tenant)

      assert again.id == definition.id
      assert definition.status == :active
      assert byte_size(definition.definition_sha256) == 32
      assert definition.tenant_id == ctx.tenant.id
      assert [event] = events_of_type(ctx.tenant, "agents.definition.registered")
      assert event.subject_id == definition.id
      assert event.payload["record_sha256"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "rejects the same name and version with a different definition", ctx do
      _ = AgentsFixtures.definition!(ctx.tenant)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.register_definition(
                 %{
                   name: "SDRAgent",
                   version: 1,
                   module: "SdrAgent.SDRAgent",
                   definition: %{"changed" => true}
                 },
                 actor: ctx.kernel
               )
    end

    test "only the kernel registers; retire is terminal", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.register_definition(%{name: "X", version: 1, module: "X", definition: %{}},
                 actor: human(:admin, ctx.tenant)
               )

      definition = AgentsFixtures.definition!(ctx.tenant)
      {:ok, retired} = Agents.retire_definition(definition, actor: ctx.kernel)
      assert retired.status == :retired
      assert {:error, _} = Agents.retire_definition(retired, actor: ctx.kernel)
      assert [_] = events_of_type(ctx.tenant, "agents.definition.retired")
    end
  end

  describe "AgentRun lifecycle" do
    test "the declared transition table matches the transition actions" do
      declared =
        AgentRun.transitions()
        |> Enum.map(fn {name, from, to} -> {name, Enum.sort(from), to} end)
        |> Enum.sort()

      actions =
        AgentRun
        |> Ash.Resource.Info.actions()
        |> Enum.flat_map(fn action ->
          Enum.flat_map(Map.get(action, :changes, []), fn
            %{change: {SdrAgent.Audit.Changes.Transition, opts}} ->
              [{action.name, Enum.sort(opts[:from]), opts[:to]}]

            _ ->
              []
          end)
        end)
        |> Enum.sort()

      assert declared == actions

      assert Enum.sort(declared) ==
               Enum.sort([
                 {:start, [:queued], :running},
                 {:succeed, [:running], :succeeded},
                 {:fail, [:running], :failed},
                 {:exhaust_budget, [:running], :budget_exhausted},
                 {:cancel, [:queued, :running], :cancelled}
               ])
    end

    test "create, start, phase, succeed — each audited with trace ids", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      assert run.status == :running
      assert run.started_at
      assert run.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert run.span_id =~ ~r/^[0-9a-f]{16}$/
      assert run.budget.max_model_calls == 20
      assert run.budget.max_tokens == 100_000

      {:ok, run} = Agents.set_run_phase(run, :qualify, actor: agent)
      assert run.phase == :qualify
      {:ok, run} = Agents.succeed_run(run, actor: agent)
      assert run.status == :succeeded
      assert run.finished_at

      types = ctx.tenant |> events() |> Enum.map(& &1.event_type)

      for type <-
            ~w(agents.run.created agents.run.started agents.run.phase_changed agents.run.succeeded) do
        assert type in types
      end

      event = List.last(events_of_type(ctx.tenant, "agents.run.succeeded"))
      assert event.agent_run_id == run.id
      assert event.payload["changes"]["status"] == "succeeded"
    end

    test "forbidden transitions are rejected and append nothing", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      {:ok, done} = Agents.succeed_run(run, actor: agent)
      count = length(events(ctx.tenant))

      assert {:error, %Ash.Error.Invalid{}} = Agents.start_run(done, actor: agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.cancel_run(done, actor: human(:admin, ctx.tenant))

      # a stale struct cannot bypass the guard: the from-state check is in the UPDATE
      assert {:error, %Ash.Error.Invalid{}} = Agents.succeed_run(run, actor: agent)
      assert length(events(ctx.tenant)) == count
    end

    test "failure and budget exhaustion require a reason", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      assert {:error, %Ash.Error.Invalid{}} = Agents.fail_run(run, %{}, actor: agent)

      {:ok, failed} =
        Agents.fail_run(
          run,
          %{status_reason: :provider_error, failure_reason: "fake provider down"}, actor: agent)

      assert failed.status == :failed
      assert failed.status_reason == :provider_error

      %{run: other} = AgentsFixtures.running_run(ctx.tenant)

      {:ok, exhausted} =
        Agents.exhaust_run_budget(other, %{status_reason: :run_budget_calls}, actor: agent)

      assert exhausted.status == :budget_exhausted
    end

    test "operators cancel and retry; retry creates a new linked run", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      reviewer = human(:reviewer, ctx.tenant)

      {:ok, cancelled} = Agents.cancel_run(run, actor: reviewer)
      assert cancelled.status == :cancelled
      assert cancelled.status_reason == :cancelled_by_operator

      {:ok, retry} = Agents.retry_run(cancelled, actor: human(:admin, ctx.tenant))
      assert retry.retry_of_id == run.id
      assert retry.status == :queued
      assert retry.budget.model_calls_reserved == 0
      assert retry.agent_definition_id == run.agent_definition_id

      %{run: live} = AgentsFixtures.running_run(ctx.tenant)
      assert {:error, %Ash.Error.Invalid{}} = Agents.retry_run(live, actor: reviewer)
    end

    test "operators cannot drive agent transitions; agents cannot retry", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.succeed_run(run, actor: human(:admin, ctx.tenant))

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.set_run_phase(run, :plan, actor: human(:reviewer, ctx.tenant))

      {:ok, failed} = Agents.fail_run(run, %{status_reason: :crash}, actor: agent)
      assert {:error, %Ash.Error.Forbidden{}} = Agents.retry_run(failed, actor: agent)
    end

    test "SCH may create runs; DLV may not", ctx do
      definition = AgentsFixtures.definition!(ctx.tenant)

      assert {:ok, _} =
               Agents.create_run(AgentsFixtures.run_attrs(definition),
                 actor: system_actor(:scheduler, ctx.tenant)
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.create_run(AgentsFixtures.run_attrs(definition),
                 actor: system_actor(:delivery_worker, ctx.tenant)
               )
    end

    test "model-call reservation is atomic and never exceeds the budget", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, max_model_calls: 3)

      results = for _ <- 1..5, do: Agents.reserve_model_call(run, actor: agent)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 2

      {:ok, reloaded} = Agents.get_run(run.id, actor: agent)
      assert reloaded.budget.model_calls_reserved == 3
    end
  end

  describe "ModelInvocation" do
    setup ctx do
      Map.merge(ctx, AgentsFixtures.running_run(ctx.tenant))
    end

    test "reserve stores the request payload, numbers the call and links the run", ctx do
      {:ok, inv} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-1"),
          actor: ctx.agent
        )

      assert inv.status == :reserved
      assert inv.sequence_in_run == 1
      assert inv.agent_run_id == ctx.run.id
      assert inv.request_sha256 == :crypto.hash(:sha256, AgentsFixtures.model_attrs("x").request)
      assert inv.trace_id =~ ~r/^[0-9a-f]{32}$/

      {:ok, request} =
        Audit.read_content(inv.request_sha256, actor: human(:admin, ctx.tenant), purpose: "t")

      assert request == AgentsFixtures.model_attrs("x").request

      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.budget.model_calls_reserved == 1

      [event] = events_of_type(ctx.tenant, "model.invocation.reserved")
      assert event.model_invocation_id == inv.id
      assert event.agent_run_id == ctx.run.id
      assert event.category == :model
      assert event.payload["changes"]["request_sha256"] == hex(inv.request_sha256)
      assert event.version_refs["prompt_templates"]["qualify_lead"] == "1"

      {:ok, second} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-2"),
          actor: ctx.agent
        )

      assert second.sequence_in_run == 2
    end

    test "completion stores the verbatim response and settles usage", ctx do
      {:ok, inv} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-c"),
          actor: ctx.agent
        )

      {:ok, inv} = Agents.mark_model_invocation_sent(inv, actor: ctx.agent)

      {:ok, done} =
        Agents.complete_model_invocation(inv, AgentsFixtures.completion(), actor: ctx.agent)

      assert done.status == :completed
      assert done.response_sha256 == :crypto.hash(:sha256, AgentsFixtures.completion().response)
      assert done.validation_status == :valid
      assert done.usage.input_tokens == 120

      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.budget.model_calls_used == 1
      assert run.budget.tokens_used == 150

      for type <- ~w(model.invocation.sent model.invocation.completed) do
        assert [_] = events_of_type(ctx.tenant, type)
      end
    end

    test "transitions are guarded; idempotency key is unique per tenant", ctx do
      {:ok, inv} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-g"),
          actor: ctx.agent
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.mark_model_invocation_unknown(inv, actor: ctx.agent)

      {:ok, sent} = Agents.mark_model_invocation_sent(inv, actor: ctx.agent)
      {:ok, unknown} = Agents.mark_model_invocation_unknown(sent, actor: ctx.agent)
      assert unknown.status == :unknown

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.complete_model_invocation(unknown, AgentsFixtures.completion(),
                 actor: ctx.agent
               )

      assert [_] = events_of_type(ctx.tenant, "model.invocation.unknown")

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-g"),
                 actor: ctx.agent
               )
    end

    test "a failed invocation records its error", ctx do
      {:ok, inv} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-f"),
          actor: ctx.agent
        )

      {:ok, failed} =
        Agents.fail_model_invocation(inv, %{error: %{"kind" => "provider_error"}},
          actor: ctx.agent
        )

      assert failed.status == :failed
      assert failed.error == %{"kind" => "provider_error"}
      assert [_] = events_of_type(ctx.tenant, "model.invocation.failed")
    end

    test "only the agent runtime records invocations", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-x"),
                 actor: system_actor(:delivery_worker, ctx.tenant)
               )
    end

    test "content is readable only through read_content", ctx do
      {:ok, inv} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-r"),
          actor: ctx.agent
        )

      {:ok, [read]} =
        Agents.list_model_invocations(ctx.run.id, actor: human(:reviewer, ctx.tenant))

      assert read.id == inv.id
      refute Map.has_key?(read, :request)
    end
  end

  describe "ToolInvocation" do
    setup ctx do
      Map.merge(ctx, AgentsFixtures.running_run(ctx.tenant, max_tool_calls: 2))
    end

    test "start and finish record payloads, counters and events", ctx do
      {:ok, tool} = Agents.start_tool_invocation(ctx.run, tool_attrs("t-1"), actor: ctx.agent)
      assert tool.status == :started
      assert tool.sequence_in_run == 1
      assert tool.input_sha256 == :crypto.hash(:sha256, ~s({"q":"acme"}))

      {:ok, done} =
        Agents.succeed_tool_invocation(
          tool,
          %{
            output: ~s({"hits":1}),
            external_request_refs: [
              %{provider: "fixture_search", request_id: "r1", target: "fixture://acme"}
            ]
          },
          actor: ctx.agent
        )

      assert done.status == :succeeded
      assert done.output_sha256 == :crypto.hash(:sha256, ~s({"hits":1}))
      assert [%{provider: "fixture_search"}] = done.external_request_refs
      assert done.finished_at
      assert is_integer(done.duration_ms)

      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.budget.tool_calls_used == 1
      assert [_] = events_of_type(ctx.tenant, "tool.invocation.started")
      assert [finished] = events_of_type(ctx.tenant, "tool.invocation.finished")
      assert finished.tool_invocation_id == tool.id
      assert finished.category == :tool
    end

    test "the tool budget is enforced and terminal states are final", ctx do
      {:ok, a} = Agents.start_tool_invocation(ctx.run, tool_attrs("t-a"), actor: ctx.agent)
      {:ok, _} = Agents.start_tool_invocation(ctx.run, tool_attrs("t-b"), actor: ctx.agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.start_tool_invocation(ctx.run, tool_attrs("t-c"), actor: ctx.agent)

      {:ok, failed} =
        Agents.fail_tool_invocation(a, %{error: %{"reason" => "timeout"}}, actor: ctx.agent)

      assert failed.status == :failed

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.mark_tool_invocation_unknown(failed, actor: ctx.agent)
    end
  end

  describe "Decision" do
    setup ctx do
      base = AgentsFixtures.running_run(ctx.tenant)

      {:ok, inv} =
        Agents.reserve_model_invocation(base.run, AgentsFixtures.model_attrs("mi-d"),
          actor: base.agent
        )

      {:ok, inv} = Agents.mark_model_invocation_sent(inv, actor: base.agent)

      {:ok, inv} =
        Agents.complete_model_invocation(inv, AgentsFixtures.completion(), actor: base.agent)

      Map.merge(ctx, Map.put(base, :invocation, inv))
    end

    test "an LLM decision links its invocation, stores inputs and is audited", ctx do
      {:ok, decision} = Agents.record_decision(llm_attrs(ctx), actor: ctx.agent)

      assert decision.model_invocation_id == ctx.invocation.id

      assert decision.inputs_sha256 ==
               :crypto.hash(
                 :sha256,
                 SdrAgent.Audit.Canonical.encode!(%{"lead" => %{"name" => "Fictional Co"}})
               )

      assert decision.idempotency_key =~ ~r/^[0-9a-f]{64}$/
      assert decision.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert decision.decided_at

      [event] = events_of_type(ctx.tenant, "agents.decision.recorded")
      assert event.decision_id == decision.id
      assert event.model_invocation_id == ctx.invocation.id
      assert event.category == :decision
      assert event.payload["record_sha256"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "re-recording the same output is a no-op", ctx do
      {:ok, first} = Agents.record_decision(llm_attrs(ctx), actor: ctx.agent)
      {:ok, again} = Agents.record_decision(llm_attrs(ctx), actor: ctx.agent)
      assert again.id == first.id
      assert [_] = events_of_type(ctx.tenant, "agents.decision.recorded")

      {:ok, other} =
        Agents.record_decision(
          llm_attrs(ctx, %{
            kind: :evidence_quality,
            output_pointer: "/criteria/industry",
            outcome: "accepted"
          }), actor: ctx.agent)

      refute other.id == first.id
    end

    test "LLM decisions require a resolvable pointer into a valid completed invocation", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(llm_attrs(ctx, %{output_pointer: "/missing"}),
                 actor: ctx.agent
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(llm_attrs(ctx, %{output_pointer: nil}), actor: ctx.agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(llm_attrs(ctx, %{rule_id: "r", rule_version: "1"}),
                 actor: ctx.agent
               )

      {:ok, open} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("mi-open"),
          actor: ctx.agent
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(llm_attrs(ctx, %{model_invocation_id: open.id}),
                 actor: ctx.agent
               )
    end

    test "deterministic decisions need a rule and no invocation", ctx do
      {:ok, decision} =
        Agents.record_decision(rule_attrs(ctx, :suppression_check), actor: ctx.agent)

      assert decision.mode == :deterministic
      assert decision.rule_id == "suppression_check"

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(rule_attrs(ctx, :phase_transition, %{rule_id: nil}),
                 actor: ctx.agent
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(
                 rule_attrs(ctx, :phase_transition, %{model_invocation_id: ctx.invocation.id}),
                 actor: ctx.agent
               )
    end

    test "protected kinds can never be decided by the model", ctx do
      for kind <-
            ~w(suppression_check send_gate quiet_hours quota_check approval_validation campaign_state_check
                     budget_reservation unsubscribe_rule delivery_reconciliation)a do
        assert {:error, %Ash.Error.Invalid{}} =
                 Agents.record_decision(llm_attrs(ctx, %{kind: kind}), actor: ctx.agent),
               "#{kind} must be deterministic"
      end
    end

    test "each system actor records only its own kinds", ctx do
      dlv = system_actor(:delivery_worker, ctx.tenant)
      assert {:ok, _} = Agents.record_decision(rule_attrs(ctx, :send_gate), actor: dlv)
      assert {:error, %Ash.Error.Forbidden{}} = Agents.record_decision(llm_attrs(ctx), actor: dlv)

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.record_decision(rule_attrs(ctx, :send_gate), actor: ctx.agent)

      assert {:ok, _} =
               Agents.record_decision(rule_attrs(ctx, :delivery_reconciliation),
                 actor: system_actor(:reconciler, ctx.tenant)
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.record_decision(rule_attrs(ctx, :send_gate),
                 actor: human(:admin, ctx.tenant)
               )
    end

    test "decisions are append-only", ctx do
      {:ok, decision} = Agents.record_decision(llm_attrs(ctx), actor: ctx.agent)

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               raw_error("UPDATE decisions SET outcome = 'forged' WHERE id = $1", [
                 Ecto.UUID.dump!(decision.id)
               ])

      assert message =~ "append-only"

      refute Enum.any?(
               Ash.Resource.Info.actions(SdrAgent.Agents.Decision),
               &(&1.type in [:update, :destroy])
             )
    end
  end

  defp tool_attrs(key),
    do: %{
      action_module: "SdrAgent.Actions.Research",
      action_version: "1",
      input: ~s({"q":"acme"}),
      idempotency_key: key
    }

  defp llm_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        agent_run_id: ctx.run.id,
        kind: :qualification,
        mode: :llm,
        subject_resource: "SdrAgent.Sales.Lead",
        subject_id: ctx.run.lead_id,
        input_refs: [
          %{
            resource: "SdrAgent.Sales.Lead",
            id: ctx.run.lead_id,
            record_sha256: hex(digest("lead"))
          }
        ],
        inputs: %{"lead" => %{"name" => "Fictional Co"}},
        model_invocation_id: ctx.invocation.id,
        output_pointer: "/qualified",
        outcome: "qualified",
        confidence: 0.82
      },
      overrides
    )
  end

  defp rule_attrs(ctx, kind, overrides \\ %{}) do
    Map.merge(
      %{
        agent_run_id: ctx.run.id,
        kind: kind,
        mode: :deterministic,
        subject_resource: "SdrAgent.Sales.Contact",
        subject_id: Ecto.UUID.generate(),
        inputs: %{"email" => "a@example.test"},
        rule_id: "#{kind}",
        rule_version: "1",
        outcome: "clear"
      },
      overrides
    )
  end
end

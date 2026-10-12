defmodule SdrAgent.Agents.ResultReadGateTest do
  @moduledoc """
  R0-07 slice A read gate (REQ-07-5; entity PASS at 1da747a, ModelInvocation
  delta). For a generation-2 ClaudeCLI invocation, `parsed_output` is
  readable only through `SdrAgent.Agents.released_output/2` (which requires
  a `:released` release) and by the witness evidence seam (REC and AUD).
  Generic Ash reads, the domain list and detail APIs, kernel-context reads,
  admins and AGT see it as forbidden — released or not. Generation-1 and
  Fake rows are unchanged. LLM Decisions refuse an unreleased output with
  `:result_not_released`.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Errors.ResultNotReleased
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Kernel

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: rec,
      invocation: AgentsFixtures.claude_completed!(run, agent, "gate-1")
    }
  end

  @output AgentsFixtures.completion().parsed_output

  defp release!(ctx, invocation) do
    link = AgentsFixtures.reconciled_link!(invocation, ctx.rec)

    {:ok, release} =
      Agents.decide_result_release(
        %{
          model_invocation_id: invocation.id,
          disposition: :released,
          reason: :reconciled,
          wire_witness_link_id: link.id
        },
        actor: ctx.agent
      )

    release
  end

  defp withhold!(ctx, invocation, reason) do
    attrs = %{model_invocation_id: invocation.id, disposition: :withheld, reason: reason}
    {:ok, release} = Agents.decide_result_release(attrs, actor: ctx.agent)
    release
  end

  # Every business read path of one invocation, as `actor`.
  defp business_reads(ctx, invocation, actor) do
    {:ok, got} = Ash.get(ModelInvocation, invocation.id, actor: actor)
    {:ok, listed} = Agents.list_model_invocations(ctx.run.id, actor: actor)
    listed = Enum.find(listed, &(&1.id == invocation.id))

    [{"Ash.get", got}, {"list_model_invocations", listed}]
  end

  defp business_actors(ctx) do
    [
      ctx.agent,
      human(:admin, ctx.tenant),
      human(:reviewer, ctx.tenant),
      human(:auditor, ctx.tenant),
      system_actor(:delivery_worker, ctx.tenant)
    ]
  end

  defp kernel_read(invocation) do
    {:ok, row} = Ash.get(ModelInvocation, invocation.id, Kernel.opts(invocation.tenant_id))
    row
  end

  defp assert_withheld(row, label) do
    assert %Ash.ForbiddenField{} = row.parsed_output, label
    # Metadata stays readable.
    assert row.status == :completed, label
    assert row.validation_status == :valid, label
  end

  describe "an unreleased generation-2 ClaudeCLI output" do
    test "is forbidden through generic, list and detail reads and kernel context", ctx do
      for actor <- business_actors(ctx),
          {label, row} <- business_reads(ctx, ctx.invocation, actor) do
        assert_withheld(row, "#{label} as #{inspect(actor)}")
      end

      assert_withheld(kernel_read(ctx.invocation), "kernel context")

      # The output does not leak through an input filter on the field either.
      {:ok, matches} =
        ModelInvocation
        |> Ash.Query.for_read(:read, %{}, actor: ctx.agent)
        |> Ash.Query.filter(id == ^ctx.invocation.id)
        |> Ash.Query.filter_input(%{parsed_output: %{is_nil: false}})
        |> Ash.read()

      assert matches == []
    end

    test "is readable by the witness evidence seam (REC and AUD)", ctx do
      for actor <- [ctx.rec, system_actor(:auditor_cli, ctx.tenant)] do
        {:ok, row} = Ash.get(ModelInvocation, ctx.invocation.id, actor: actor)
        assert row.parsed_output == @output, inspect(actor)
      end

      assert {:ok, %{request: request}} =
               Agents.read_reconciliation_payloads(ctx.invocation, actor: ctx.rec)

      assert is_binary(request)
    end

    test "is readable under the test-seam calibration context only (as AGT)", ctx do
      context = SdrAgent.Agents.Checks.CalibrationContext.context(:claude_cli_opus)

      {:ok, row} = Ash.get(ModelInvocation, ctx.invocation.id, actor: ctx.agent, context: context)
      assert row.parsed_output == @output

      # The marker does nothing for any other actor.
      for actor <- [human(:admin, ctx.tenant), system_actor(:delivery_worker, ctx.tenant)] do
        {:ok, row} = Ash.get(ModelInvocation, ctx.invocation.id, actor: actor, context: context)
        assert_withheld(row, inspect(actor))
      end
    end

    test "released_output/2 refuses it with :result_not_released", ctx do
      for actor <- [ctx.agent, human(:admin, ctx.tenant), system_actor(:kernel, ctx.tenant)] do
        assert {:error, :result_not_released} =
                 Agents.released_output(ctx.invocation, actor: actor),
               inspect(actor)
      end
    end

    test "a withheld output stays refused everywhere", ctx do
      withhold!(ctx, ctx.invocation, :witness_mismatch)

      assert {:error, :result_not_released} =
               Agents.released_output(ctx.invocation.id, actor: ctx.agent)

      for {label, row} <- business_reads(ctx, ctx.invocation, ctx.agent),
          do: assert_withheld(row, label)
    end
  end

  describe "a released output" do
    test "is returned by released_output/2 only; generic reads still see it withheld", ctx do
      release!(ctx, ctx.invocation)

      for actor <- [ctx.agent, human(:admin, ctx.tenant), system_actor(:kernel, ctx.tenant)] do
        assert {:ok, @output} = Agents.released_output(ctx.invocation, actor: actor),
               inspect(actor)
      end

      for {label, row} <- business_reads(ctx, ctx.invocation, ctx.agent),
          do: assert_withheld(row, label)

      assert_withheld(kernel_read(ctx.invocation), "kernel context")
    end

    test "released_output/2 is scoped to the actor's tenant and needs an actor", ctx do
      release!(ctx, ctx.invocation)

      stranger = %{system_actor(:agent_runtime, ctx.tenant) | tenant_id: Ecto.UUID.generate()}

      for actor <- [stranger, nil] do
        assert {:error, _} = Agents.released_output(ctx.invocation, actor: actor), inspect(actor)
      end
    end
  end

  describe "rows outside the gate" do
    test "Fake and generation-1 outputs are unchanged", ctx do
      {:ok, fake} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("gate-fake"),
          actor: ctx.agent
        )

      {:ok, fake} = Agents.mark_model_invocation_sent(fake, actor: ctx.agent)

      {:ok, fake} =
        Agents.complete_model_invocation(fake, AgentsFixtures.completion(), actor: ctx.agent)

      legacy = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-legacy")

      tamper!(
        "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
          "allocation_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(legacy.id)]
      )

      for invocation <- [fake, legacy] do
        for actor <- business_actors(ctx),
            {label, row} <- business_reads(ctx, invocation, actor) do
          assert row.parsed_output == @output, "#{label} as #{inspect(actor)}"
        end

        assert kernel_read(invocation).parsed_output == @output
        assert {:ok, @output} = Agents.released_output(invocation, actor: ctx.agent)
      end
    end
  end

  describe "LLM decisions (DecisionRules)" do
    defp llm_decision(ctx, invocation, key) do
      Agents.record_decision(
        %{
          agent_run_id: ctx.run.id,
          kind: :qualification,
          mode: :llm,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: ctx.run.lead_id,
          model_invocation_id: invocation.id,
          output_pointer: "/qualified",
          outcome: "qualified",
          idempotency_key: "gate-decision-#{key}",
          inputs: %{"lead" => ctx.run.lead_id}
        },
        actor: ctx.agent
      )
    end

    test "refuse an unreleased or withheld output with :result_not_released", ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = llm_decision(ctx, ctx.invocation, "u")
      assert Enum.any?(errors, &match?(%ResultNotReleased{}, &1)), inspect(errors)

      withheld = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-withheld")
      withhold!(ctx, withheld, :witness_timeout)
      assert {:error, %Ash.Error.Invalid{errors: errors}} = llm_decision(ctx, withheld, "w")
      assert Enum.any?(errors, &match?(%ResultNotReleased{}, &1)), inspect(errors)

      assert {:ok, []} = Agents.list_decisions(ctx.run.id, actor: ctx.agent)
    end

    test "accept a released output, and resolve the pointer in it", ctx do
      release!(ctx, ctx.invocation)
      assert {:ok, decision} = llm_decision(ctx, ctx.invocation, "r")
      assert decision.model_invocation_id == ctx.invocation.id

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.record_decision(
                 %{
                   agent_run_id: ctx.run.id,
                   kind: :qualification,
                   mode: :llm,
                   subject_resource: "SdrAgent.Sales.Lead",
                   subject_id: ctx.run.lead_id,
                   model_invocation_id: ctx.invocation.id,
                   output_pointer: "/missing",
                   outcome: "qualified",
                   idempotency_key: "gate-decision-missing",
                   inputs: %{}
                 },
                 actor: ctx.agent
               )
    end
  end

  test "the chain verifier still checks generation-2 invocation rows", ctx do
    release!(ctx, ctx.invocation)
    assert {:ok, report} = SdrAgent.Audit.verify_chain(actor: human(:admin, ctx.tenant))
    assert report.valid?, inspect(report.issues)
  end
end

defmodule SdrAgent.Agents.LaunchAdmissionTest do
  @moduledoc """
  C9-03 (R0 readiness packet, `Agents.admit_launch/3`): a reserved ClaudeCLI
  invocation is admitted again just before launch. For an owned, reserved
  generation-2 row the complete non-room predicate is re-checked against the
  current terms (profile, grant status and window, grant profiles,
  allocation grant, profile restriction, bucket and availability); a failed
  check moves it reserved → failed (never sent) and, in the same committed
  transaction, opens one `provider_error` Failure of the run and appends
  `model.launch.refused`; the caller gets the typed receipt `%Refused{stage:
  :launch}` (R0-07 slice B, row B1: the Failure's subject is the run, so the
  run stop links it instead of opening a second one). Room is grandfathered: the
  attempt was charged at reservation. Identity and state refusals (missing,
  foreign, replayed, terminal, not ClaudeCLI) change nothing.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure

  @now ~U[2026-10-20 12:00:00.000000Z]
  @starts ~U[2026-10-12 00:00:00.000000Z]
  @expires ~U[2026-11-06 00:00:00.000000Z]
  @run_resource "SdrAgent.Agents.AgentRun"

  setup do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)

    grant =
      AgentsFixtures.grant!(
        tenant,
        %{
          total_attempts: 10,
          starts_at: @starts,
          expires_at: @expires,
          allocations: [%{key: :b1, applies_to: [:b1], attempts: 10}]
        },
        admin
      )

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    %{tenant: tenant, admin: admin, grant: grant, run: run, agent: agent}
  end

  defp reserve!(ctx, key, overrides \\ %{}) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))
      |> Map.merge(overrides)

    {:ok, invocation} = Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.agent)
    invocation
  end

  defp admit(ctx, id, profile \\ :claude_cli_opus),
    do: Agents.admit_launch(id, profile, actor: ctx.agent)

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp launch_failures(ctx) do
    Failure
    |> Ash.Query.filter(class == :provider_error and subject_resource == ^@run_resource)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

  defp edit!(ctx, attrs) do
    {:ok, grant} = Agents.get_grant(ctx.grant.id, actor: ctx.admin)

    {:ok, grant} =
      Agents.update_grant_terms(grant, Map.put(attrs, :expected_revision, grant.revision),
        actor: ctx.admin
      )

    grant
  end

  # The row was refused at launch: failed, never sent, with the reason, and
  # one critical provider_error Failure of its run (R0-07 slice B, row B1).
  defp assert_refused_at_launch(ctx, invocation, reason) do
    refused = stored(invocation.id)
    assert refused.status == :failed
    assert refused.sent_at == nil
    assert refused.error["kind"] == "launch_refused"
    assert refused.error["reason"] == Atom.to_string(reason)

    assert [failure] =
             ctx |> launch_failures() |> Enum.filter(&(&1.subject_id == invocation.agent_run_id))

    assert failure.severity == :critical
    assert failure.status == :open

    refute Enum.any?(
             events_of_type(ctx.tenant, "model.invocation.sent"),
             &(&1.model_invocation_id == invocation.id)
           )

    assert Enum.any?(
             events_of_type(ctx.tenant, "model.invocation.failed"),
             &(&1.model_invocation_id == invocation.id)
           )

    refused
  end

  describe "an owned reserved row whose terms still admit it" do
    test "is marked sent and committed", ctx do
      invocation = reserve!(ctx, "ok")

      assert {:ok, sent} = admit(ctx, invocation.id)
      assert sent.id == invocation.id
      assert sent.status == :sent
      assert sent.sent_at == @now
      assert stored(invocation.id).status == :sent
      assert launch_failures(ctx) == []

      assert [_] =
               Enum.filter(
                 events_of_type(ctx.tenant, "model.invocation.sent"),
                 &(&1.model_invocation_id == invocation.id)
               )
    end

    test "a Sonnet row launches under the Sonnet profile", ctx do
      invocation =
        reserve!(
          ctx,
          "sonnet",
          SdrAgent.AI.ModelProvider.ClaudeCLI.provenance(:claude_cli_sonnet)
        )

      assert {:ok, %{status: :sent}} = admit(ctx, invocation.id, :claude_cli_sonnet)
    end

    test "a lowered cap still launches the already charged calls (room grandfathered)", ctx do
      first = reserve!(ctx, "cap-1")
      second = reserve!(ctx, "cap-2")

      edit!(ctx, %{
        total_attempts: 1,
        per_utc_day_attempts: 1,
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]
      })

      assert {:ok, %{status: :sent}} = admit(ctx, first.id)
      assert {:ok, %{status: :sent}} = admit(ctx, second.id)
    end

    test "the call that took the last slot launches", ctx do
      edit!(ctx, %{total_attempts: 1, allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]})
      last = reserve!(ctx, "last")

      assert {:error, _refused} =
               Agents.reserve_model_invocation(ctx.run, AgentsFixtures.claude_attrs("over"),
                 actor: ctx.agent
               )

      assert {:ok, %{status: :sent}} = admit(ctx, last.id)
    end
  end

  describe "an owned reserved row whose terms changed is refused, failed and never sent" do
    test "after the grant expired", ctx do
      invocation = reserve!(ctx, "expired")
      Clock.freeze(@expires)

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "grant_expired"
    end

    test "after the grant was revoked", ctx do
      invocation = reserve!(ctx, "revoked")
      {:ok, _} = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "grant_revoked"
    end

    test "after the grant's start moved later", ctx do
      invocation = reserve!(ctx, "later-start")
      edit!(ctx, %{starts_at: DateTime.add(@now, 1, :day)})

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "grant_not_started"
    end

    test "after its profile was removed from the grant", ctx do
      invocation = reserve!(ctx, "profile-removed")
      edit!(ctx, %{profile_ids: [:claude_cli_sonnet]})

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "profile_not_in_grant"
    end

    test "when the allocation's profile restriction no longer matches", ctx do
      invocation = reserve!(ctx, "restricted")

      # A restriction is part of the allocation's identity and cannot be
      # edited; the check is defensive, so the row is changed behind the app.
      tamper!(
        "UPDATE model_call_allocations SET profile_id = 'claude_cli_sonnet' WHERE id = $1",
        [
          Ecto.UUID.dump!(invocation.allocation_id)
        ]
      )

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "allocation_profile_restricted"
    end

    test "after its usage bucket was removed from the allocation", ctx do
      invocation = reserve!(ctx, "bucket-removed")
      edit!(ctx, %{allocations: [%{key: :b1, applies_to: [:b2], attempts: 10}]})

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "bucket_not_applicable"
    end

    test "after the allocation window closed", ctx do
      invocation = reserve!(ctx, "window-closed")

      edit!(ctx, %{
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 10, available_until: @now}]
      })

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :grant_ineligible_at_launch)
      assert refused.error["check"] == "allocation_unavailable"
    end

    test "when the server's effective profile is not the reserved one", ctx do
      invocation = reserve!(ctx, "mismatch")

      assert {:error, %Refused{stage: :launch, reason: :profile_mismatch_at_launch}} =
               admit(ctx, invocation.id, :claude_cli_sonnet)

      refused = assert_refused_at_launch(ctx, invocation, :profile_mismatch_at_launch)
      assert refused.error["check"] == "profile_mismatch"
    end

    test "a generation-1 (pre-R0) reserved row is refused as legacy and failed", ctx do
      invocation = reserve!(ctx, "legacy")

      tamper!(
        "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
          "allocation_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(invocation.id)]
      )

      assert {:error, %Refused{stage: :launch, reason: :legacy_invocation_without_grant}} =
               admit(ctx, invocation.id)

      refused = assert_refused_at_launch(ctx, invocation, :legacy_invocation_without_grant)
      assert refused.ledger_generation == 1
    end

    test "a refused row cannot be admitted afterwards", ctx do
      invocation = reserve!(ctx, "refused-once")
      {:ok, _} = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)

      assert {:error, %Refused{stage: :launch, reason: :grant_ineligible_at_launch}} =
               admit(ctx, invocation.id)

      assert {:error, :invocation_not_reserved} = admit(ctx, invocation.id)
      assert length(launch_failures(ctx)) == 1
    end
  end

  describe "a run stopped while its call was queued" do
    # Each stop the run lifecycle allows from running (AgentRun.transitions/0).
    defp stop!(ctx, run, :cancelled), do: Agents.cancel_run(run, actor: ctx.admin)
    defp stop!(_ctx, run, :succeeded), do: Agents.succeed_run(run, actor: run_agent(run))

    defp stop!(_ctx, run, :failed),
      do:
        Agents.fail_run(run, %{status_reason: :crash, failure_reason: "stopped"},
          actor: run_agent(run)
        )

    defp stop!(_ctx, run, :budget_exhausted),
      do:
        Agents.exhaust_run_budget(run, %{status_reason: :run_budget_tokens},
          actor: run_agent(run)
        )

    defp run_agent(run), do: system_actor(:agent_runtime, %{id: run.tenant_id})

    test "is refused at launch, failed and never sent, with no launch Failure", ctx do
      for status <- [:cancelled, :succeeded, :failed, :budget_exhausted] do
        %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
        invocation = reserve!(%{ctx | run: run, agent: agent}, "stopped-#{status}")
        {:ok, stopped} = stop!(ctx, run, status)
        assert stopped.status == status

        assert {:error, :run_not_running_at_launch} =
                 Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)

        refused = stored(invocation.id)
        assert {refused.status, refused.sent_at} == {:failed, nil}

        assert refused.error == %{
                 "kind" => "launch_refused",
                 "reason" => "run_not_running_at_launch",
                 "check" => Atom.to_string(status)
               }

        # The run's own stop is its cause; launch admission adds no Failure.
        assert ctx |> launch_failures() |> Enum.filter(&(&1.subject_id == run.id)) == []

        {:ok, after_refusal} = Agents.get_run(run.id, actor: agent)
        assert after_refusal.status == status
        assert after_refusal.attention_failure_id == stopped.attention_failure_id
        assert after_refusal.budget.model_calls_used == stopped.budget.model_calls_used

        refute Enum.any?(
                 events_of_type(ctx.tenant, "model.invocation.sent"),
                 &(&1.model_invocation_id == invocation.id)
               )
      end
    end

    test "a running run's call still launches", ctx do
      invocation = reserve!(ctx, "still-running")
      assert {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.status == :running
      assert {:ok, %{status: :sent}} = admit(ctx, invocation.id)
    end
  end

  describe "identity and state refusals change nothing" do
    test "a replayed sent id is refused; the row is untouched", ctx do
      invocation = reserve!(ctx, "replay")
      assert {:ok, sent} = admit(ctx, invocation.id)
      before = stored(invocation.id)

      assert {:error, :invocation_not_reserved} = admit(ctx, invocation.id)
      assert stored(invocation.id) == before
      assert before.sent_at == sent.sent_at

      # The sent call still settles normally.
      assert {:ok, completed} =
               Agents.complete_model_invocation(before, AgentsFixtures.completion(),
                 actor: ctx.agent
               )

      assert completed.status == :completed
      assert launch_failures(ctx) == []
    end

    test "terminal ids are refused with their rows unchanged", ctx do
      completed = reserve!(ctx, "terminal-completed")
      {:ok, sent} = admit(ctx, completed.id)

      {:ok, completed} =
        Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: ctx.agent)

      failed = reserve!(ctx, "terminal-failed")

      {:ok, failed} =
        Agents.fail_model_invocation(failed, %{error: %{"kind" => "x"}}, actor: ctx.agent)

      for row <- [completed, failed] do
        before = stored(row.id)
        assert {:error, :invocation_not_reserved} = admit(ctx, row.id)
        assert stored(row.id) == before
      end

      assert launch_failures(ctx) == []
    end

    test "missing, malformed and foreign ids are refused with every row unchanged", ctx do
      invocation = reserve!(ctx, "foreign")
      before = stored(invocation.id)
      foreign = system_actor(:agent_runtime, %{id: Ecto.UUID.generate()})

      assert {:error, :invocation_not_found} = admit(ctx, Ash.UUIDv7.generate())
      assert {:error, :invocation_not_found} = admit(ctx, "../../not-a-uuid")
      assert {:error, :invocation_not_found} = admit(ctx, nil)

      assert {:error, :invocation_not_found} =
               Agents.admit_launch(invocation.id, :claude_cli_opus, actor: foreign)

      assert stored(invocation.id) == before
      assert launch_failures(ctx) == []
    end

    test "a Fake invocation is not a launch", ctx do
      {:ok, fake} =
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("fake"),
          actor: ctx.agent
        )

      before = stored(fake.id)
      assert {:error, :invocation_not_claude_cli} = admit(ctx, fake.id, :fake)
      assert {:error, :invocation_not_claude_cli} = admit(ctx, fake.id)
      assert stored(fake.id) == before
    end

    test "identity refusals are audited for the current tenant", ctx do
      invocation = reserve!(ctx, "audited")
      {:ok, _} = admit(ctx, invocation.id)
      missing = Ash.UUIDv7.generate()

      assert {:error, :invocation_not_reserved} = admit(ctx, invocation.id)
      assert {:error, :invocation_not_found} = admit(ctx, missing)

      events = events_of_type(ctx.tenant, "model.launch.refused")

      assert Enum.map(events, &{&1.subject_id, &1.payload["reason"]}) == [
               {invocation.id, "invocation_not_reserved"},
               {missing, "invocation_not_found"}
             ]

      assert Enum.map(events, & &1.model_invocation_id) == [invocation.id, nil]
    end

    test "only agent_runtime may admit a launch", ctx do
      invocation = reserve!(ctx, "actor")
      before = stored(invocation.id)

      for actor <- [
            ctx.admin,
            human(:reviewer, ctx.tenant),
            system_actor(:scheduler, ctx.tenant),
            system_actor(:kernel, ctx.tenant),
            nil
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Agents.admit_launch(invocation.id, :claude_cli_opus, actor: actor),
               inspect(actor)
      end

      assert stored(invocation.id) == before
      assert length(events_of_type(ctx.tenant, "authz.denied")) >= 4
    end
  end
end

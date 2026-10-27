defmodule SdrAgent.Agents.FundedScopeAdmissionTest do
  @moduledoc """
  C2* S2 RED-4 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC10,
  AC12, §5 "`admission/agent_env_guard.ex`" and §7 row
  "funded_scope_admission_test.exs"; Codex plan/entity PASS `aa42492e`,
  OQ5-OQ7 and R5; ADR-0004 agent-environment item 9a): the funded scope at
  reservation, in a spend-ready agent environment.

  The only funded scope is `[{:assignment, [:qualification,
  :evidence_extraction, :outreach_proposal]}]`. After the single allocation
  is selected and before room, a call charged to a delegated grant, or any
  real call in a configured agent environment, outside it is refused as
  `Admission.Refused` `:outside_funded_scope` with a closed `check`
  (`:origin_purpose`, `:not_spend_ready`, `:grant_not_delegated`,
  `:authorization_mismatch`, `:database_binding`, …): no invocation, no
  counter change, one Failure (class `:provider_error`) and one
  `model.reservation.refused` event, and the run stops
  `:model_not_admitted`. Origins whose bucket no `[:b1]` allocation funds
  stay `:no_allocation` (OQ7); a profile outside the grant stays
  `:no_eligible_grant`; the three funded purposes are admitted (T-F5).
  `Admission.agent_env_reasons/0` lists the three new reasons, each an
  admission reason (AC12).

    * T-F1 (selector off), T-F2, T-F4, OQ6, T-F5 and AC12, at reservation.
    * **Deferred until S3 merges** (its selector and demo window are absent
      on this base; no S3 interface is stood in for here): T-F1 with the
      selector on, and the order "funded scope before S3's demo window".

  Fixtures: a delegated grant provisioned through the GREEN-2 route and the
  run side (`spend_ready!/1`), or an SQL-level delegated stand-in where
  provisioning refuses the environment (`stand_in_spend_ready!/2`); runs are
  created before the environment is configured. Synthetic registry entries
  only; no model call is made (reservation only).

  RED: no funded-scope guard exists, so each out-of-scope call is admitted
  today (behavioural); `agent_env_reasons/0` is absent (structural guard).
  The `:no_allocation`, `:no_eligible_grant`, T-F5 and unknown-reason cases
  are controls (pass now and after GREEN).
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Context
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @moduletag :c2star_s2

  @funded [:qualification, :evidence_extraction, :outreach_proposal]

  setup do
    AdmissionFixtures.admit_tuples!()
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## Helpers

  # A running run with its Operation, created before any configuration.
  defp run!(ctx, origin), do: AgentsFixtures.operated_run(ctx.tenant, usage_origin: origin)

  defp reserve(run, key, overrides) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))
      |> Map.merge(overrides)

    Agents.reserve_model_invocation(run.run, attrs, actor: run.agent)
  end

  defp invocations(run) do
    ModelInvocation
    |> Ash.Query.filter(agent_run_id == ^run.run.id)
    |> Ash.count!(authorize?: false)
  end

  defp failures(ctx), do: Ash.read!(Failure, Audit.Kernel.opts(ctx.tenant.id))

  defp refusal_events(ctx), do: events_of_type(ctx.tenant, "model.reservation.refused")

  defp model_ctx(ctx, run) do
    %Context{
      actor: run.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.run.id,
      correlation_id: run.run.correlation_id
    }
  end

  defp reload(run) do
    {:ok, stored} = Agents.get_run(run.run.id, actor: run.agent)
    stored
  end

  # The full refusal receipt at reservation: the typed refusal and check,
  # nothing charged, one :provider_error Failure, one refusal event.
  defp assert_outside_scope(ctx, run, result, check, label) do
    assert match?(
             {:error, %Refused{stage: :reservation, reason: :outside_funded_scope}},
             result
           ),
           "c2star-s2: #{label}: expected :outside_funded_scope, got " <>
             inspect(result, limit: 8, printable_limit: 400)

    {:error, refused} = result
    assert refused.check == check, "c2star-s2: #{label}: check #{inspect(refused.check)}"
    assert invocations(run) == 0, "c2star-s2: #{label}: an invocation was written"

    assert [failure] = Enum.filter(failures(ctx), &(&1.id == refused.failure_id))
    assert failure.class == :provider_error
    assert [event] = Enum.filter(refusal_events(ctx), &(&1.id == refused.event_id))

    assert {event.payload["reason"], event.payload["check"]} ==
             {"outside_funded_scope", Atom.to_string(check)}

    refused
  end

  defp revoke!(ctx, grant) do
    result = Agents.revoke_grant(grant, %{expected_revision: 1}, actor: ctx.admin)
    assert match?({:ok, %{status: :revoked}}, result), "fixture: revoke: #{inspect(result)}"
  end

  ## T-F1, T-F2 (origin and purpose)

  describe "origin and purpose (T-F1, T-F2)" do
    test "an assignment run's reply_classification call is outside the funded scope", ctx do
      run = run!(ctx, :assignment)
      env = spend_ready!()
      before = Agents.daily_model_calls(ctx.tenant.id)

      result = reserve(run, "tf1", %{purpose: :reply_classification})
      assert_outside_scope(ctx, run, result, :origin_purpose, "assignment/reply_classification")
      assert Agents.daily_model_calls(ctx.tenant.id) == before

      assert {:ok, %{} = usage} = Agents.grant_usage([env.grant.id], actor: ctx.admin)
      assert usage[env.grant.id].consumed == 0
    end

    test "a referral run's qualification call is outside the funded scope", ctx do
      run = run!(ctx, :referral)
      spend_ready!()

      result = reserve(run, "tf2-referral", %{purpose: :qualification})
      assert_outside_scope(ctx, run, result, :origin_purpose, "referral/qualification")
    end

    # OQ7: no [:b1] allocation funds these origins' buckets, so selection
    # refuses them before the scope check, unchanged.
    for origin <- [:reply, :followup, :discovery, :channel] do
      @tag origin: origin
      test "control: a #{origin} run is refused :no_allocation before any charge", ctx do
        run = run!(ctx, ctx.origin)
        spend_ready!()
        result = reserve(run, "tf2-#{ctx.origin}", %{purpose: :qualification})

        assert match?({:error, %Refused{reason: :no_allocation}}, result),
               "control: #{ctx.origin}: #{inspect(result, limit: 6)}"

        assert invocations(run) == 0
      end
    end
  end

  ## T-F4, OQ6 (the environment and the grant)

  describe "the environment and the grant (T-F4, OQ6)" do
    test "an environment that is not spend-ready refuses: :not_spend_ready", ctx do
      run = run!(ctx, :assignment)
      env = spend_ready!()
      File.rm!(Fx.path(env.root, :authorization))

      result = reserve(run, "tf4-not-ready", %{purpose: :qualification})
      assert_outside_scope(ctx, run, result, :not_spend_ready, "no authorization.json")
    end

    test "a delegated grant of another authorization refuses: :authorization_mismatch", ctx do
      run = run!(ctx, :assignment)
      env = spend_ready!()
      revoke!(ctx, env.grant)
      other = delegated_row!(ctx.tenant)
      assert other.delegated_authorization_id != env.entry.id

      result = reserve(run, "tf4-other-auth", %{purpose: :qualification})
      assert_outside_scope(ctx, run, result, :authorization_mismatch, "another authorization")
    end

    test "a live database other than the binding's refuses: :database_binding", ctx do
      run = run!(ctx, :assignment)
      {_database, live_oid} = Fx.live_identity!()
      stand_in_spend_ready!(ctx.tenant, database_oid: live_oid + 1)

      result = reserve(run, "tf4-oid", %{purpose: :qualification})
      assert_outside_scope(ctx, run, result, :database_binding, "oid + 1")
    end

    test "an owner-form grant in the agent environment refuses: :grant_not_delegated (OQ6)",
         ctx do
      run = run!(ctx, :assignment)

      owner =
        AgentsFixtures.grant!(
          ctx.tenant,
          %{
            total_attempts: 4,
            profile_ids: [:claude_cli_opus],
            starts_at: ~U[2026-10-27 00:00:00.000000Z],
            expires_at: ~U[2026-10-31 00:00:00.000000Z],
            allocations: [%{key: :b1, applies_to: [:b1], attempts: 4}]
          },
          ctx.admin
        )

      env = spend_ready!()
      revoke!(ctx, env.grant)

      result = reserve(run, "oq6", %{purpose: :qualification})
      refused = assert_outside_scope(ctx, run, result, :grant_not_delegated, "owner-form grant")
      assert refused.failure_id
      assert owner.provisioning == :owner_form
    end

    test "control: a profile outside the grant is refused :no_eligible_grant before any charge",
         ctx do
      run = run!(ctx, :assignment)
      spend_ready!()

      result =
        reserve(run, "tf4-profile", %{purpose: :qualification, profile_id: :claude_cli_sonnet})

      assert match?({:error, %Refused{reason: :no_eligible_grant}}, result), inspect(result)
      assert invocations(run) == 0
    end
  end

  ## T-F5

  describe "the funded scope (T-F5)" do
    for purpose <- @funded do
      @tag purpose: purpose
      test "control: an assignment run's #{purpose} call is admitted and charged", ctx do
        run = run!(ctx, :assignment)
        env = spend_ready!()
        result = reserve(run, "tf5-#{ctx.purpose}", %{purpose: ctx.purpose})

        assert match?({:ok, %ModelInvocation{}}, result),
               "control: #{ctx.purpose}: #{inspect(result, limit: 8, printable_limit: 400)}"

        {:ok, invocation} = result
        assert invocation.grant_id == env.grant.id
      end
    end
  end

  ## AC12

  describe "the reason mappings (AC12, R5)" do
    test "agent_env_reasons/0 lists the three reasons, each an admission reason", _ctx do
      require_function!(Admission, :agent_env_reasons, 0)
      reasons = invoke(Admission, :agent_env_reasons, [])

      assert Enum.sort(reasons) ==
               Enum.sort([:outside_funded_scope, :agent_env_lease_mismatch, :agent_env_expired])

      for reason <- reasons do
        assert Admission.admission_reason?(reason),
               "c2star-s2: #{reason} is not an admission reason"
      end
    end

    test "a funded-scope refusal stops the run :model_not_admitted on its Failure", ctx do
      run = run!(ctx, :assignment)
      spend_ready!()
      result = reserve(run, "ac12", %{purpose: :reply_classification})
      refused = assert_outside_scope(ctx, run, result, :origin_purpose, "ac12")

      assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx(ctx, run), reload(run), refused)
      assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}
      assert stopped.attention_failure_id == refused.failure_id
    end

    test "control: an unknown reason is never mapped to a run stop", ctx do
      run = run!(ctx, :assignment)

      unknown = %Refused{
        reason: :c2star_s2_unknown_reason,
        failure_id: Ecto.UUID.generate(),
        event_id: Ecto.UUID.generate(),
        agent_run_id: run.run.id,
        stage: :reservation
      }

      result =
        try do
          {:returned, SDR.Model.stop_refused(model_ctx(ctx, run), reload(run), unknown)}
        rescue
          error -> {:raised, error}
        end

      refute match?({:returned, {:ok, _stopped}}, result),
             "control: an unknown reason stopped the run: #{inspect(result, limit: 6)}"

      assert reload(run).status == :running
    end
  end
end

defmodule SdrAgent.Agents.AgentEnvLaunchTest do
  @moduledoc """
  C2* S2 RED-4 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC10,
  AC11, §5 "`admission/agent_env_guard.ex`" (`launch/5`, order lease →
  terminal expiry → funded scope) and §7 row "agent_env_launch_test.exs";
  Codex plan/entity PASS `aa42492e`, OQ3-OQ5; ADR-0004 agent-environment
  items 5, 9a and 11): the agent-environment guard at launch, after the gate
  and the switch fence and before the grant's launch terms.

  A call reserved in a spend-ready environment and refused at launch is a
  `Refused{stage: :launch}`: the row `failed`, never sent, still charged
  (consumption unchanged), one `model.launch.refused` event, and the run
  stops `:model_not_admitted` on its Failure.

    * **T-V4 (launch half):** the run lease's nonce changed, or the lease
      removed, after the reservation → `:agent_env_lease_mismatch`.
    * **T-F3:** the authorization file's digest, or the registry entry,
      changed after the reservation → `:outside_funded_scope`.
    * **T-W5 (launch, S2 half):** the grant revoked, or the clock at the
      registry entry's `expires_at`, after the reservation →
      `:agent_env_expired`, not `:grant_ineligible_at_launch` (OQ5).
    * **Control:** a consistent environment's launch is admitted and sent.

  **Deferred, for review:** the plan's integrated variant
  (`ModelProvider.complete/2` through the fake-launcher server, proving the
  fake CLI never spawns) and the order "lease check before S3's demo window"
  (S3 not merged on this base). Here the launch is admitted or refused
  through `Agents.admit_launch/3`, as `launch_gate_test.exs` does.

  RED: no agent-environment guard exists at launch, so each case is
  admitted today, or refused `:grant_ineligible_at_launch` (revocation,
  expiry) (behavioural). The control passes now and after GREEN.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
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

  setup do
    AdmissionFixtures.admit_tuples!()
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    run = AgentsFixtures.operated_run(tenant, usage_origin: :assignment)
    env = spend_ready!()
    %{tenant: tenant, admin: admin, run: run, env: env}
  end

  ## Helpers

  defp reserve!(ctx, key) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))
      |> Map.put(:purpose, :qualification)

    result = Agents.reserve_model_invocation(ctx.run.run, attrs, actor: ctx.run.agent)

    assert match?({:ok, %ModelInvocation{}}, result),
           "fixture: reservation in the spend-ready environment: " <>
             inspect(result, limit: 8, printable_limit: 400)

    elem(result, 1)
  end

  defp admit(ctx, invocation),
    do: Agents.admit_launch(invocation.id, :claude_cli_opus, actor: ctx.run.agent)

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp consumed(grant) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp failures(ctx), do: Ash.read!(Failure, Audit.Kernel.opts(ctx.tenant.id))

  defp model_ctx(ctx) do
    %Context{
      actor: ctx.run.agent,
      tenant_id: ctx.tenant.id,
      run_id: ctx.run.run.id,
      correlation_id: ctx.run.run.correlation_id
    }
  end

  defp reload(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.run.id, actor: ctx.run.agent)
    run
  end

  # The launch refusal receipt: typed refusal, failed and unsent row still
  # charged, one launch event, the run stopped on the Failure.
  defp assert_launch_refused(ctx, invocation, reason, label) do
    before = consumed(ctx.env.grant)
    result = admit(ctx, invocation)

    assert match?({:error, %Refused{stage: :launch, reason: ^reason}}, result),
           "c2star-s2: #{label}: expected #{inspect(reason)} at launch, got " <>
             inspect(result, limit: 8, printable_limit: 400)

    {:error, refused} = result
    row = stored(invocation.id)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert row.error["reason"] == Atom.to_string(reason)
    assert consumed(ctx.env.grant) == before, "c2star-s2: #{label}: the charge changed"

    assert [failure] = Enum.filter(failures(ctx), &(&1.id == refused.failure_id))
    assert failure.class == :provider_error

    assert [event] =
             ctx.tenant
             |> events_of_type("model.launch.refused")
             |> Enum.filter(&(&1.model_invocation_id == invocation.id))

    assert event.payload["reason"] == Atom.to_string(reason)

    assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx(ctx), reload(ctx), refused)
    assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}
  end

  ## Control

  test "control: a consistent environment's launch is admitted and sent", ctx do
    invocation = reserve!(ctx, "launch-control")
    result = admit(ctx, invocation)
    assert match?({:ok, _sent}, result), "control: #{inspect(result, limit: 6)}"
    assert stored(invocation.id).status == :sent
  end

  ## T-V4 (launch half)

  describe "the run lease (T-V4, launch half)" do
    test "a lease nonce changed after the reservation refuses :agent_env_lease_mismatch", ctx do
      invocation = reserve!(ctx, "tv4-nonce")
      Fx.tamper!(ctx.env.root, :lease)
      assert_launch_refused(ctx, invocation, :agent_env_lease_mismatch, "lease nonce changed")
    end

    test "a lease removed after the reservation refuses :agent_env_lease_mismatch", ctx do
      invocation = reserve!(ctx, "tv4-removed")
      File.rm!(Fx.path(ctx.env.root, :lease))
      assert_launch_refused(ctx, invocation, :agent_env_lease_mismatch, "lease removed")
    end
  end

  ## T-F3

  describe "authorization drift (T-F3)" do
    test "an authorization digest changed after the reservation refuses :outside_funded_scope",
         ctx do
      invocation = reserve!(ctx, "tf3-digest")
      {:valid, _sha256, final} = SdrAgent.AgentEnv.State.read(ctx.env.root, :authorization)

      Fx.write_state!(
        ctx.env.root,
        :authorization,
        Map.put(final, "authorization_sha256", rand_hex(32))
      )

      assert_launch_refused(ctx, invocation, :outside_funded_scope, "authorization digest drift")
    end

    test "a registry entry changed after the reservation refuses :outside_funded_scope", ctx do
      invocation = reserve!(ctx, "tf3-registry")
      put_test_entries!([%{ctx.env.entry | total_attempts: 5}])
      assert_launch_refused(ctx, invocation, :outside_funded_scope, "registry entry drift")
    end
  end

  ## T-W5 (launch, S2 half)

  describe "terminal expiry (T-W5, launch)" do
    test "a grant revoked after the reservation refuses :agent_env_expired", ctx do
      invocation = reserve!(ctx, "tw5-revoked")
      revoked = Agents.revoke_grant(ctx.env.grant, %{expected_revision: 1}, actor: ctx.admin)
      assert match?({:ok, %{status: :revoked}}, revoked), "fixture: #{inspect(revoked)}"
      assert_launch_refused(ctx, invocation, :agent_env_expired, "revoked")
    end

    test "the clock at the registry entry's expires_at refuses :agent_env_expired", ctx do
      invocation = reserve!(ctx, "tw5-expired")
      Clock.freeze(ctx.env.entry.expires_at)
      assert_launch_refused(ctx, invocation, :agent_env_expired, "entry expires_at")
    end
  end
end

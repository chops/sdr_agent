defmodule SdrAgent.Agents.DelegatedBudgetTest do
  @moduledoc """
  C2* S2 RED-4 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC13
  and §7 row "delegated_budget_test.exs"; Codex plan/entity PASS `aa42492e`;
  ADR-0004 agent-environment item 7): the delegated grant's budget in a
  spend-ready agent environment, derived from its invocations and surviving
  a fresh process and configuration.

    * **T-B2:** failed, unknown, launch-refused and completed invocations
      all count; the next reservation at the total is
      `{:budget_exhausted, :grant}`.
    * **T-B4:** with a per-day limit of 2 consumed, a reservation from a new
      process under a new run nonce is `{:budget_exhausted, :grant_day}`;
      with the daily model-call limit 2 consumed, it is the bare
      `{:budget_exhausted, :daily}`.
    * **T-B1 (grant half):** after N are consumed, a new root and nonce and a
      re-run of provisioning replay the same grant; `grant_usage/2` is N and
      exactly total − N more are admitted.
    * **T-B3 (grant half):** an environment whose oid is not the live
      database's refuses provisioning (`:binding_mismatch`) with no second
      grant. Its admission half (`:database_binding`) is in
      `funded_scope_admission_test.exs`.

  Not covered here: the "completed but withheld (empty allowlist)" variant
  of T-B2 (a completed invocation counts the same way; release withholding
  does not change its charge).

  RED: these budget rules are derived from invocations today, so every test
  here is expected to pass now and after GREEN (controls: they guard that
  the funded-scope guard keeps them; none is a RED failure).
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @moduletag :c2star_s2

  @window {~U[2026-10-28 00:00:00.000000Z], ~U[2026-10-31 00:00:00.000000Z]}

  setup do
    AdmissionFixtures.admit_tuples!()
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    run = AgentsFixtures.operated_run(tenant, usage_origin: :assignment, max_model_calls: 50)
    %{tenant: tenant, admin: human(:admin, tenant), run: run}
  end

  ## Helpers

  # One `:rehearsal` allocation over the whole window (synthetic).
  defp entry(total, per_day) do
    test_entry(%{
      total_attempts: total,
      per_utc_day_attempts: per_day,
      allocations: [alloc(:rehearsal, total, @window)]
    })
  end

  defp reserve(ctx, key) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))

    Agents.reserve_model_invocation(ctx.run.run, attrs, actor: ctx.run.agent)
  end

  defp reserve!(ctx, key) do
    result = reserve(ctx, key)
    assert match?({:ok, %ModelInvocation{}}, result), "fixture: #{key}: #{inspect(result)}"
    elem(result, 1)
  end

  defp consumed(grant) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  # A new run lease and run configuration for the same environment.
  defp new_run_nonce!(env) do
    nonce = Fx.write_lease!(env.root, :run, env.bound.binding_sha256)
    Fx.configure!(env.root, mode: :run, nonce: nonce)
    nonce
  end

  defp in_new_process(fun), do: fun |> Task.async() |> Task.await(30_000)

  ## T-B2

  test "failed, unknown, launch-refused and completed invocations all count (T-B2)", ctx do
    env = spend_ready!(entry: entry(4, nil))
    agent = ctx.run.agent

    failed = reserve!(ctx, "tb2-failed")

    assert {:ok, _} =
             Agents.fail_model_invocation(failed, %{error: %{"kind" => "x"}}, actor: agent)

    unknown = reserve!(ctx, "tb2-unknown")
    assert {:ok, sent} = Agents.mark_model_invocation_sent(unknown, actor: agent)
    assert {:ok, _} = Agents.mark_model_invocation_unknown(sent, actor: agent)

    refused = reserve!(ctx, "tb2-launch-refused")

    assert {:error, %Refused{stage: :launch}} =
             Agents.admit_launch(refused.id, :claude_cli_sonnet, actor: agent)

    AgentsFixtures.claude_completed!(ctx.run.run, agent, "tb2-completed")

    assert consumed(env.grant) == 4

    assert match?(
             {:error, %Refused{reason: {:budget_exhausted, :grant}}},
             reserve(ctx, "tb2-over")
           )
  end

  ## T-B4

  test "the per-day limit survives a new process and run nonce (T-B4)", ctx do
    env = spend_ready!(entry: entry(6, 2))
    reserve!(ctx, "tb4-1")
    reserve!(ctx, "tb4-2")
    new_run_nonce!(env)

    result = in_new_process(fn -> reserve(ctx, "tb4-3") end)

    assert match?({:error, %Refused{reason: {:budget_exhausted, :grant_day}}}, result),
           inspect(result, limit: 6)
  end

  test "the daily model-call limit survives a new process and run nonce (T-B4)", ctx do
    previous = Application.fetch_env(:sdr_agent, :daily_model_call_limit)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :daily_model_call_limit, value)
        :error -> Application.delete_env(:sdr_agent, :daily_model_call_limit)
      end
    end)

    Application.put_env(:sdr_agent, :daily_model_call_limit, 2)
    env = spend_ready!(entry: entry(6, nil))
    reserve!(ctx, "daily-1")
    reserve!(ctx, "daily-2")
    new_run_nonce!(env)

    assert in_new_process(fn -> reserve(ctx, "daily-3") end) ==
             {:error, {:budget_exhausted, :daily}}
  end

  ## T-B1, T-B3 (grant halves)

  test "a new root, nonce and provisioning re-run replay the grant; usage carries (T-B1)", ctx do
    first = spend_ready!(entry: entry(4, nil))
    reserve!(ctx, "tb1-1")
    reserve!(ctx, "tb1-2")

    second = spend_ready!(entry: first.entry)
    assert second.root != first.root
    assert second.grant.id == first.grant.id
    assert Ash.Resource.get_metadata(second.grant, :sdr_replayed) == true

    assert {:ok, usage} = Agents.grant_usage([first.grant.id], actor: ctx.admin)
    assert usage[first.grant.id].consumed == 2

    reserve!(ctx, "tb1-3")
    reserve!(ctx, "tb1-4")

    assert match?(
             {:error, %Refused{reason: {:budget_exhausted, :grant}}},
             reserve(ctx, "tb1-5")
           )
  end

  test "an environment oid other than the live one refuses provisioning, no second grant (T-B3)",
       ctx do
    env = spend_ready!()
    {_database, live_oid} = Fx.live_identity!()
    provisioning_env!(entry: env.entry, database_oid: live_oid + 1)

    result = provision(env.entry.id, actor: prv(ctx.tenant))
    assert refused?(result, :binding_mismatch), inspect(result, limit: 6)

    delegated =
      ModelCallGrant
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provisioning == :delegated))

    assert Enum.map(delegated, & &1.id) == [env.grant.id]
  end
end

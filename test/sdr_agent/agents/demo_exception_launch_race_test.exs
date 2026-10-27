defmodule SdrAgent.Agents.DemoExceptionLaunchRaceTest do
  @moduledoc """
  C2* S3 RED-5, T-L5's launch-admission participant (S3 plan r2 §8 T-L5;
  draft T-L5 "a launch admission"; ADR-0005 C2* item 6). It races
  `Agents.admit_launch/3`, which takes the run `FOR UPDATE`, the Operation
  `FOR SHARE`, the invocation `FOR UPDATE`, the charged grant then
  allocation `FOR SHARE`, then the head, and then (GREEN-5) the window
  guard's under-head reads. Its opponent is an eligible finalizer, which
  takes the run `FOR UPDATE`, the Operation, the invocation `FOR SHARE`,
  the current links `FOR SHARE`, the grant then allocation `FOR SHARE`, and
  then the head. The two belong to different runs funded by the same grant
  and allocation, so they share only `FOR SHARE` row locks and meet at the
  chain head.

  It needs real connections, so it is `sandbox: false` and kept in its own
  file. A holder takes the head. The first contender is observed waiting on
  the holder and the second on the first (the head's queue), each asserted
  (`pg_stat_activity`, `pg_blocking_pids/1`) before the holder commits.
  Both orders are run. Both complete with no deadlock: the launch is sent,
  and the finalizer decides the exception (one release).

  Coverage (qualified): a lock either side takes after the head that
  conflicts with the other side's pre-head share locks (for example a grant
  or allocation `FOR UPDATE` under the head) deadlocks, in the order where
  that side acquires the head first, and fails here. A post-head lock
  compatible with `FOR SHARE`, and a pre-head order inversion, are not
  discriminated here. Both contenders already hold their pre-head locks
  when they queue, and the T-L4 order traces stay the evidence for those.

  Rows: the file commits real rows in the owned lane database and removes
  them itself (`TRUNCATE … CASCADE` over an explicit table list including
  `tenants`, before each test and in `on_exit`). The admission
  configuration (the v3 Opus entry plus the real profiles' admission
  entries, and a trusted store root) is set once per test, so no
  contender changes the Application env while the other runs.

  Classification (RED-5 at b30364b9): `control:`. Today's launch has no
  guard and passes; these tests must stay green when GREEN-5 adds it.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import SdrAgent.AuditCase, only: [system_actor: 2]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.Repo

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants
             approvals revision_citations draft_revisions drafts suppressions
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions settings_revisions run_settings_snapshots delivery_operations)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    env = Fx.demo_env!()
    entries = [Fx.v3_opus() | Enum.map(ModelProfiles.real_ids(), &AdmissionFixtures.entry/1)]
    AdmissionFixtures.admit_tuples!(entries: entries)
    %{env: env}
  end

  for {label, order} <- [
        {"the launch first, then the finalizer", [:launch, :finalize]},
        {"the finalizer first, then the launch", [:finalize, :launch]}
      ] do
    @tag order: order
    test "control: T-L5 a launch admission and a finalizer of another run meet at the head, " <>
           "#{label}: no deadlock",
         %{env: env} = ctx do
      parts = Fx.constructed!(env)
      other = other_call!(env)

      contenders = %{
        launch: fn ->
          Agents.admit_launch(other.invocation.id, :claude_cli_opus, actor: other.agent)
        end,
        finalize: fn ->
          ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})
        end
      }

      results = race_at_head(env, ctx.order, contenders)

      assert {:ok, %{status: :sent}} = results.launch
      assert {:released, %{disposition: :demo_exception} = release, _output} = results.finalize
      assert releases(env) == [release.id]
      assert Ash.get!(ModelInvocation, other.invocation.id, authorize?: false).status == :sent
    end
  end

  ## Harness

  # Another operated run on the same fixture lead, with a reserved real
  # call charged to the demo grant's one allocation (committed).
  defp other_call!(env) do
    %{run: run, agent: agent} = AgentsFixtures.operated_run(env.tenant, lead_id: Fx.lead_id())
    key = "launch-race-#{System.unique_integer([:positive])}"
    attrs = key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"request":"#{key}"}))
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    assert {invocation.grant_id, invocation.allocation_id} == {env.grant.id, env.allocation.id}
    %{run: run, agent: agent, invocation: invocation}
  end

  # A holder takes the head; the contenders start in `order`, the first
  # observed waiting on the holder and the second on the first; then the
  # holder commits and both are awaited.
  defp race_at_head(env, [first, second], contenders) do
    parent = self()
    holder = Task.async(fn -> with_connection(fn -> head_holder(env, parent) end) end)
    assert_receive {:holder, holder_pid}, 10_000

    one = start_contender(parent, first, Map.fetch!(contenders, first))
    assert_receive {^first, first_pid}, 10_000
    blocked!(first_pid, holder_pid)

    two = start_contender(parent, second, Map.fetch!(contenders, second))
    assert_receive {^second, second_pid}, 10_000
    blocked!(second_pid, first_pid)

    send(holder.pid, :finish)
    Task.await(holder, 30_000)
    %{first => Task.await(one, 30_000), second => Task.await(two, 30_000)}
  end

  defp head_holder(env, parent),
    do: {:ok, :ok} = Audit.transaction(fn -> hold_head(env, parent) end)

  defp hold_head(env, parent) do
    {:ok, _head} = Kernel.lock_head(env.tenant.id)
    send(parent, {:holder, backend_pid()})

    receive do
      :finish -> :ok
    after
      30_000 -> raise "the holder was never told to finish"
    end
  end

  defp start_contender(parent, tag, fun) do
    Task.async(fn ->
      with_connection(fn ->
        send(parent, {tag, backend_pid()})
        fun.()
      end)
    end)
  end

  # The barrier's positive control: `pid` is waiting on a lock, and `holder`
  # is among the backends blocking it.
  defp blocked!(pid, holder) do
    waiting =
      Enum.find_value(1..250, fn _ ->
        Process.sleep(20)

        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]).rows do
          [["Lock"]] -> true
          _ -> nil
        end
      end)

    assert waiting, "backend #{pid} never waited on a lock"
    assert [[blockers]] = Repo.query!("SELECT pg_blocking_pids($1)", [pid]).rows
    assert holder in blockers, "backend #{pid} is not blocked by #{holder}: #{inspect(blockers)}"
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp releases(env) do
    auditor = system_actor(:auditor_cli, env.tenant)
    {:ok, all} = Agents.list_result_releases(actor: auditor)
    Enum.map(all, & &1.id)
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp cleanup! do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end

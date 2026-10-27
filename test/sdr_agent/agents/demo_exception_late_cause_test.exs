defmodule SdrAgent.Agents.DemoExceptionLateCauseTest do
  @moduledoc """
  C2* S3 GREEN-4 M1 RED (Codex 6be502a0; plan r2 §6 Recovery; AC10): the
  deduplicated fixed cause "demo exception not in use" must be reused when
  another writer commits it while Recovery is waiting for the chain head,
  i.e. after Recovery's pre-head selection found none. Recovery must not
  open a duplicate, decide a release, append a release event or return the
  output.

  It needs two real connections, so it is `sandbox: false` and kept in its
  own file (not `demo_exception_race_test.exs`). The barrier is
  deterministic: a holder transaction takes the head and reports its
  backend pid; Recovery (no use authority: the clock is past the effective
  end) reports its pid and starts; the test waits until PostgreSQL shows
  Recovery waiting on a lock held by the holder (`pg_stat_activity`,
  `pg_blocking_pids/1`) and asserts it (the positive control that the
  barrier engaged). Only then does the holder open and commit the matching
  warning, as a system writer (`Operations.open_failure/2`), and release
  the head.

  Rows: the file commits real rows in the owned lane database and removes
  them itself (`TRUNCATE … CASCADE` over an explicit table list including
  `tenants`, before each test and in `on_exit`). Every task is awaited on
  the passing path; on a failure before `:finish` they are linked to the
  test process.

  Classification (at 193346d7): behavioural. Recovery opens a second
  warning from its stale empty pre-head selection.

  RED-5 boundary control (Codex aaea2f45, item 2): the second-change branch
  of the accepted GREEN-4 M1 fix (b30364b9), `{:error,
  :demo_cause_changed}` with nothing written, covered dynamically. The
  first holder holds the head while Recovery waits behind it; a second
  holder then queues for the head behind Recovery (asserted: Recovery
  blocks it). The first holder commits a matching warning. Recovery sees it
  under the head and rolls back to its pre-head savepoint, which releases
  the head while its transaction stays open: only then does the second
  holder get the head (asserted, with Recovery still running). Recovery
  re-selects (now holding the first warning) and waits for the head again,
  this time on the second holder (asserted). The second holder commits
  another matching warning. Recovery's under-head re-read differs a second
  time, so it fails closed: the run is not stopped, no cause is opened by
  Recovery, and every new audit event is one of the two writers'.
  Classification: `control:` (tests-after-GREEN coverage of b30364b9; the
  barrier and queue assertions are its own positive controls).
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import SdrAgent.AuditCase, only: [events: 1, human: 2]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.Operations
  alias SdrAgent.Repo

  @end_at ~U[2026-11-01 06:00:00.000000Z]
  @message "demo exception not in use"
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
    %{env: Fx.demo_env!()}
  end

  test "a matching warning committed while Recovery waits for the head is reused, " <>
         "never duplicated",
       %{env: env} do
    demo = Fx.demo_invocation!(env)
    admin = human(:admin, env.tenant)
    :ok = Clock.freeze(DateTime.add(@end_at, 1, :second))
    assert fixed_causes(demo, admin) == []
    before = release_events(env)
    parent = self()

    holder =
      Task.async(fn ->
        with_connection(fn ->
          {:ok, cause} = Audit.transaction(fn -> hold_then_open(env, demo, parent) end)
          cause
        end)
      end)

    assert_receive {:holder, holder_pid}, 10_000

    recovery =
      Task.async(fn ->
        with_connection(fn ->
          send(parent, {:recovery, backend_pid()})
          Recovery.run(demo.invocation, Fx.gate(env))
        end)
      end)

    assert_receive {:recovery, recovery_pid}, 10_000
    blocked!(recovery_pid, holder_pid)

    send(holder.pid, :finish)
    late = Task.await(holder, 30_000)
    result = Task.await(recovery, 30_000)

    assert Enum.map(fixed_causes(demo, admin), & &1.id) == [late.id]
    assert {:withheld, release, run} = result
    assert release.id == demo.release.id
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
    assert run.attention_failure_id == late.id
    assert release_events(env) == before
  end

  test "control: a second matching warning committed while Recovery waits for the head " <>
         "again fails closed (:demo_cause_changed), writing nothing",
       %{env: env} do
    demo = Fx.demo_invocation!(env)
    admin = human(:admin, env.tenant)
    :ok = Clock.freeze(DateTime.add(@end_at, 1, :second))
    assert fixed_causes(demo, admin) == []
    before = MapSet.new(events(env.tenant), & &1.id)
    parent = self()

    first = writer(fn -> hold_then_open(env, demo, parent) end)
    assert_receive {:holder, first_pid}, 10_000

    recovery =
      Task.async(fn ->
        with_connection(fn ->
          send(parent, {:recovery, backend_pid()})
          Recovery.run(demo.invocation, Fx.gate(env))
        end)
      end)

    assert_receive {:recovery, recovery_pid}, 10_000
    blocked!(recovery_pid, first_pid)

    # The second holder queues for the head behind Recovery.
    second = writer(fn -> queue_then_open(env, demo, parent, :second) end)
    assert_receive {:second, second_pid}, 10_000
    blocked!(second_pid, recovery_pid)
    refute_received {:second, :locked}

    # The first warning commits; Recovery sees it under the head and rolls
    # back to its savepoint, releasing the head with its transaction open.
    send(first.pid, :finish)
    one = Task.await(first, 30_000)
    assert_receive {:second, :locked}, 10_000
    assert Task.yield(recovery, 0) == nil

    # Recovery re-selected and now waits for the head on the second holder.
    blocked!(recovery_pid, second_pid)
    send(second.pid, :finish)
    two = Task.await(second, 30_000)

    assert Task.await(recovery, 30_000) == {:error, :demo_cause_changed}
    assert Enum.sort(Enum.map(fixed_causes(demo, admin), & &1.id)) == Enum.sort([one.id, two.id])
    {:ok, run} = Agents.get_run(env.run.id, actor: env.agent)
    assert {run.status, run.attention_failure_id} == {:running, nil}
    added = Enum.reject(events(env.tenant), &MapSet.member?(before, &1.id))
    assert added != [] and Enum.all?(added, &(&1.subject_id in [one.id, two.id])), inspect(added)
  end

  ## Harness

  # The holder: the head, the barrier report, then (on :finish) the exact
  # fixed warning opened by a system writer, committed with the head.
  defp hold_then_open(env, demo, parent) do
    {:ok, _head} = Kernel.lock_head(env.tenant.id)
    send(parent, {:holder, backend_pid()})
    finish_then_open(env, demo)
  end

  # A holder that reports its pid before it queues for the head, then that
  # it holds it.
  defp queue_then_open(env, demo, parent, tag) do
    send(parent, {tag, backend_pid()})
    {:ok, _head} = Kernel.lock_head(env.tenant.id)
    send(parent, {tag, :locked})
    finish_then_open(env, demo)
  end

  defp finish_then_open(env, demo) do
    receive do
      :finish ->
        {:ok, cause} =
          Operations.open_failure(
            %{
              subject_resource: "SdrAgent.Agents.ModelInvocation",
              subject_id: demo.invocation.id,
              class: :reconciliation_required,
              severity: :warning,
              message: @message,
              retryable: false,
              operation_id: env.run.operation_id
            },
            actor: SdrAgent.Actor.system(:reconciler, env.tenant.id)
          )

        cause
    after
      30_000 -> raise "the holder was never told to finish"
    end
  end

  # A committed writer transaction on its own connection; returns its cause.
  defp writer(fun) do
    Task.async(fn ->
      with_connection(fn ->
        {:ok, cause} = Audit.transaction(fun)
        cause
      end)
    end)
  end

  defp fixed_causes(demo, admin) do
    {:ok, failures} = Operations.list_attention(actor: admin)
    Enum.filter(failures, &(&1.subject_id == demo.invocation.id and &1.message == @message))
  end

  defp release_events(env),
    do: Enum.count(events(env.tenant), &String.starts_with?(&1.event_type, "model.result."))

  # The barrier's positive control: `pid` waits on a lock and `holder` is
  # among the backends blocking it.
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

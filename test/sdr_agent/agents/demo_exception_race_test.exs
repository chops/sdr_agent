defmodule SdrAgent.Agents.DemoExceptionRaceTest do
  @moduledoc """
  C2* S3 RED-4, concurrency of the exception branch (plan r2 §8 row
  `demo_exception_race_test.exs`: T-L5 and concurrent T-R1; T-L3 deferred
  here from RED-3; ADR-0005 C2* item 6), with `sandbox: false`, each side
  on its own connection.

  Every race is driven by a deterministic barrier, never by sleeping: a
  holder transaction takes its locks and reports its backend pid; the
  contender reports its pid and starts; the test waits until PostgreSQL
  shows the contender waiting on a lock held by that holder
  (`pg_stat_activity.wait_event_type = 'Lock'`, `pg_blocking_pids/1`) and
  asserts it (the positive control that the barrier engaged); only then is
  the holder told to finish.

    * T-L5, grant editor (grant → allocation → head) committing a
      revocation while the finalizer waits at the grant: no deadlock; the
      finalizer refuses under the head (`scope_mismatch`) and writes nothing.
    * T-L5, reconciler (invocation `FOR UPDATE` → head): no deadlock; the
      finalizer then decides the exception.
    * Concurrent T-R1: two eligible finalizers; one row and one event; the
      second is an identical replay with the output.
    * T-L3: a contact edit committed while the finalizer waits for the head
      is seen under the head (`scope_mismatch`). The edit is the
      database-administrator tamper fixture (no domain writer can store a
      non-reserved email in test builds).

  Classification (RED-4 at 109b2614): these exercise GREEN-3's lock order
  and under-head re-read, so they are disclosed tests-after-GREEN coverage
  (`control:`); the barrier assertions are their own positive controls.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import SdrAgent.AuditCase, only: [human: 2, events_of_type: 2, system_actor: 2]

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
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
    %{env: Fx.demo_env!()}
  end

  test "control: T-L5 a grant editor's revocation, committed while the finalizer waits, " <>
         "refuses it under the head; no deadlock, nothing written",
       %{env: env} do
    parts = Fx.constructed!(env)
    admin = human(:admin, env.tenant)

    hold = fn ->
      lock!(ModelCallGrant, env.grant.id, env.tenant.id, "FOR UPDATE")
      lock!(ModelCallAllocation, env.allocation.id, env.tenant.id, "FOR UPDATE")
      {:ok, _head} = Kernel.lock_head(env.tenant.id)
    end

    finish = fn ->
      {:ok, _} =
        Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: admin)
    end

    result = race(hold, finish, fn -> finalize(env, parts) end)
    assert result == {:error, {:demo_exception_refused, :scope_mismatch}}
    assert releases(env) == []
  end

  test "control: T-L5 the reconciler's invocation lock then head; the finalizer waits, " <>
         "then decides the exception",
       %{env: env} do
    parts = Fx.constructed!(env)

    hold = fn ->
      lock!(ModelInvocation, parts.invocation.id, env.tenant.id, "FOR UPDATE")
      {:ok, _head} = Kernel.lock_head(env.tenant.id)
    end

    result = race(hold, fn -> :ok end, fn -> finalize(env, parts) end)
    assert {:released, %{disposition: :demo_exception} = release, _output} = result
    assert releases(env) == [release.id]
  end

  test "control: concurrent T-R1 two eligible finalizers give one row and one event; " <>
         "the second replays it with the output",
       %{env: env} do
    parts = Fx.constructed!(env)
    parent = self()
    holder = start_holder(parent, fn -> {:ok, _} = Kernel.lock_head(env.tenant.id) end)
    assert_receive {:holder, holder_pid}, 10_000

    first = start_contender(parent, :first, fn -> finalize(env, parts) end)
    assert_receive {:first, first_pid}, 10_000
    blocked!(first_pid, holder_pid)

    second = start_contender(parent, :second, fn -> finalize(env, parts) end)
    assert_receive {:second, second_pid}, 10_000
    blocked!(second_pid, first_pid)

    send(holder.pid, :finish)
    Task.await(holder, 30_000)

    assert {:released, one, _output} = Task.await(first, 30_000)
    assert {:released, two, output} = Task.await(second, 30_000)
    assert {one.id, two.id} == {one.id, one.id}
    assert is_map(output)
    assert releases(env) == [one.id]
    assert length(events_of_type(env.tenant, "model.result.demo_exception")) == 1
  end

  test "control: T-L3 a contact edit committed while the finalizer waits for the head " <>
         "is seen under the head",
       %{env: env} do
    parts = Fx.constructed!(env)
    hold = fn -> {:ok, _head} = Kernel.lock_head(env.tenant.id) end

    edit = fn ->
      tamper!(
        "UPDATE contacts SET email = 'avery.lindqvist@gmail.com' " <>
          "WHERE id = (SELECT contact_id FROM leads WHERE id = $1::text::uuid)",
        [env.run.lead_id]
      )
    end

    result = race(hold, edit, fn -> finalize(env, parts) end)
    assert result == {:error, {:demo_exception_refused, :scope_mismatch}}
    assert releases(env) == []
  end

  ## Harness

  defp finalize(env, parts),
    do: ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})

  # The holder takes its locks (`hold`), the contender starts and must be
  # seen waiting on the holder before the holder runs `finish` and commits.
  defp race(hold, finish, contend) do
    parent = self()
    holder = start_holder(parent, hold, finish)
    assert_receive {:holder, holder_pid}, 10_000

    contender = start_contender(parent, :contender, contend)
    assert_receive {:contender, contender_pid}, 10_000
    blocked!(contender_pid, holder_pid)

    send(holder.pid, :finish)
    Task.await(holder, 30_000)
    Task.await(contender, 30_000)
  end

  defp start_holder(parent, hold, finish \\ fn -> :ok end) do
    Task.async(fn -> with_connection(fn -> holder_transaction(parent, hold, finish) end) end)
  end

  defp holder_transaction(parent, hold, finish) do
    {:ok, _} = Audit.transaction(fn -> hold_then_finish(parent, hold, finish) end)
  end

  defp hold_then_finish(parent, hold, finish) do
    hold.()
    send(parent, {:holder, backend_pid()})

    receive do
      :finish -> finish.()
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

  defp lock!(resource, id, tenant_id, mode) do
    {:ok, %{}} =
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(mode)
      |> Ash.read_one()
  end

  defp tamper!(sql, params) do
    SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
    SQL.query!(Repo, sql, params)
    SQL.query!(Repo, "SET LOCAL session_replication_role = origin", [])
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

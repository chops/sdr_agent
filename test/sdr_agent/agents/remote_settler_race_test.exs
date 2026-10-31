defmodule SdrAgent.Agents.RemoteSettlerRaceTest do
  @moduledoc """
  S-B3 RED items 6 (concurrent pair), 7 and 8 (behavioural) (entity/plan
  r1 670c22e4 + r2 9f3168cc; Codex PASS nits: unlocked selection, then run
  → Operation (share) → invocation → call; never the MacWorker lock), on
  independent database connections and transactions (no shared Sandbox
  owner), as `remote_race_test.exs`.

  Contract specified here:

  - two concurrent settler passes on one due pending call: exactly one
    pending → expired_unclaimed and one invocation failure, both passes
    succeed;
  - settler vs `Agents.admit_launch/3` on a due pending remote call, in
    both lock orders: no deadlock, no sent transition, the call expired
    unclaimed and the invocation failed exactly once;
  - settler vs complete at the result deadline, in both lock orders: no
    deadlock, complete is `:late`, the call expired_unknown and the
    invocation unknown, each transition event exactly once, no result;
  - the settler finishes while another transaction holds the MacWorker
    row `FOR UPDATE` (it never waits on that lock).

  Ordering is forced by a holder that locks the run row (or the worker row)
  in its own transaction; each waiter is observed blocked through
  `pg_blocking_pids` before the next starts. The clock is frozen in the
  test process (participants read it through `$callers`). Fixture rows are
  committed on real connections and removed on exit (this test's tenant
  rows and provenance snapshots only). Synthetic data only; no model, no
  CLI.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S
  alias SdrAgent.Repo

  @bound 20_000

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    provenance_before = provenance_ids()
    on_exit(fn -> with_connection(fn -> cleanup!(provenance_before) end) end)
    supervisor = start_supervised!(Task.Supervisor)

    fx = F.world!()
    F.remote!()
    %{fx: fx, supervisor: supervisor}
  end

  ## Holders, steps and invariants

  defp lock_run!(fx) do
    table = AshPostgres.DataLayer.Info.table(AgentRun)
    SQL.query!(Repo, ~s[SELECT 1 FROM "#{table}" WHERE id = $1 FOR UPDATE], [F.dump(fx.run.id)])
  end

  defp lock_worker!(worker) do
    table = F.table(F.worker_resource())
    SQL.query!(Repo, ~s[SELECT 1 FROM "#{table}" WHERE id = $1 FOR UPDATE], [F.dump(worker.id)])
  end

  defp ordinary! do
    _ = PrototypeFixtures.leave_runtime()
    :ok
  end

  # The settler step; the entry and marker are asserted in the test process
  # first, so a missing contract fails there, not inside a participant.
  defp settler_step(fx) do
    :ok = S.settler_entry!()
    opts = S.settler_opts(fx)

    fn ->
      ordinary!()
      S.settle_due(opts)
    end
  end

  # A due pending call: reserved now, the clock frozen at its claim deadline.
  defp due_pending!(fx) do
    invocation = F.reserve!(fx)
    row = F.call_of(invocation.id)
    assert row, "prerequisite: no RemoteModelCall for the remote reservation"
    Clock.freeze(F.ts(row["claim_deadline"]))
    %{invocation: invocation, call_id: F.load(row["id"])}
  end

  defp count(fx, type, id), do: F.subject_count(fx, type, id)

  ## Item 6: the concurrent pair

  test "item 6: two concurrent settler passes on one due call: exactly one transition", ctx do
    step = settler_step(ctx.fx)
    p = due_pending!(ctx.fx)

    results = ordered(ctx, fn -> lock_run!(ctx.fx) end, [step, step])

    assert Enum.all?(results, &S.ok?/1), "settler passes: #{inspect(results)}"
    assert F.call_row(p.call_id)["state"] == "expired_unclaimed"
    assert S.invocation_row(p.invocation.id)["status"] == "failed"
    assert count(ctx.fx, "remote_call.expired_unclaimed", p.call_id) == 1
    assert count(ctx.fx, "model.invocation.failed", p.invocation.id) == 1
  end

  ## Item 7: lock order

  for order <- [:settler_first, :admit_first] do
    test "item 7: settler vs admit_launch (#{order}): no deadlock, one expiry, never sent", ctx do
      settle = settler_step(ctx.fx)
      p = due_pending!(ctx.fx)

      admit = fn ->
        ordinary!()
        Agents.admit_launch(p.invocation.id, p.invocation.profile_id, actor: ctx.fx.agent)
      end

      {steps, pick} =
        if unquote(order) == :settler_first,
          do: {[settle, admit], fn [s, a] -> {s, a} end},
          else: {[admit, settle], fn [a, s] -> {s, a} end}

      {settled, admitted} = pick.(ordered(ctx, fn -> lock_run!(ctx.fx) end, steps))

      assert S.ok?(settled), "settler: #{inspect(settled)}"
      assert match?({:error, _}, admitted), "admit_launch launched: #{inspect(admitted)}"
      assert F.call_row(p.call_id)["state"] == "expired_unclaimed"
      assert S.invocation_row(p.invocation.id)["status"] == "failed"
      assert count(ctx.fx, "model.invocation.sent", p.invocation.id) == 0
      assert count(ctx.fx, "remote_call.expired_unclaimed", p.call_id) == 1
      assert count(ctx.fx, "model.invocation.failed", p.invocation.id) == 1
    end
  end

  for order <- [:settler_first, :complete_first] do
    test "item 7: settler vs complete at the result deadline (#{order}): no deadlock, one expiry",
         ctx do
      settle = settler_step(ctx.fx)
      c = S.claimed!(ctx.fx)
      Clock.freeze(F.ts(F.call_row(c.call_id)["result_deadline"]))
      bytes = S.valid_transcript()

      complete = fn ->
        ordinary!()
        F.complete(c.token, c.nonce, c.call_id, c.launch.request_sha256, bytes)
      end

      {steps, pick} =
        if unquote(order) == :settler_first,
          do: {[settle, complete], fn [s, k] -> {s, k} end},
          else: {[complete, settle], fn [k, s] -> {s, k} end}

      {settled, completed} = pick.(ordered(ctx, fn -> lock_run!(ctx.fx) end, steps))

      assert S.ok?(settled), "settler: #{inspect(settled)}"
      assert F.kind(completed) == :late, "complete: #{inspect(completed)}"
      assert F.call_row(c.call_id)["state"] == "expired_unknown"
      assert S.invocation_row(c.invocation.id)["status"] == "unknown"
      assert count(ctx.fx, "remote_call.expired_unknown", c.call_id) == 1
      assert count(ctx.fx, "model.invocation.unknown", c.invocation.id) == 1
      assert F.count(F.result_resource(), "call_id = $1", [F.dump(c.call_id)]) == 0
    end
  end

  ## Item 8: behavioural

  test "item 8: the settler finishes while the MacWorker row is held FOR UPDATE", ctx do
    settle = settler_step(ctx.fx)
    c = S.claimed!(ctx.fx)
    Clock.freeze(F.ts(F.call_row(c.call_id)["result_deadline"]))

    holder = holder(ctx, :worker_holder, fn -> lock_worker!(c.worker) end)

    result =
      joined([holder], fn ->
        settler = participant(ctx, :settler, settle)

        joined([settler], fn ->
          # Awaited while the worker lock is still held: a settler that
          # requested the MacWorker lock would never finish here.
          settled = await(settler)
          release(holder)
          assert {:ok, :held} == await(holder)
          settled
        end)
      end)

    assert S.ok?(result), "settler: #{inspect(result)}"
    assert F.call_row(c.call_id)["state"] == "expired_unknown"
    assert S.invocation_row(c.invocation.id)["status"] == "unknown"
  end

  ## Participants (as remote_race_test.exs)

  defp ordered(ctx, lock, steps) do
    holder = holder(ctx, :holder, lock)

    joined([holder], fn ->
      participants =
        steps
        |> Enum.with_index()
        |> Enum.map(fn {step, i} ->
          p = participant(ctx, {:step, i}, step)
          await_waiting(p)
          p
        end)

      joined(participants, fn ->
        release(holder)
        assert {:ok, :held} == await(holder)
        Enum.map(participants, &await/1)
      end)
    end)
  end

  defp participant(ctx, tag, fun) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        with_connection(fn ->
          send(parent, {:backend, tag, backend()})
          fun.()
        end)
      end)

    assert_receive {:backend, ^tag, backend}, @bound
    {task, backend}
  end

  defp holder(ctx, tag, lock) do
    parent = self()

    held =
      participant(ctx, tag, fn ->
        Audit.transaction(fn ->
          lock.()
          send(parent, {:held, tag})

          receive do
            :go -> :held
          after
            @bound -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:held, ^tag}, @bound
    held
  end

  defp release({task, _backend}), do: send(task.pid, :go)

  defp await({task, _backend}) do
    case Task.yield(task, @bound) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> flunk("participant did not finish: #{inspect(other)}")
    end
  end

  defp joined(participants, fun) do
    fun.()
  after
    Enum.each(participants, fn {task, _} -> Task.shutdown(task, :brutal_kill) end)
  end

  defp backend, do: hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))

  defp await_waiting(participant, attempts \\ 400)

  defp await_waiting({_, backend}, 0), do: flunk("backend #{backend} never waited on a lock")

  defp await_waiting({_, backend} = p, attempts) do
    %{rows: [[waiting?]]} =
      SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1::int)) > 0", [backend])

    unless waiting? do
      Process.sleep(25)
      await_waiting(p, attempts - 1)
    end
  end

  ## Fixture database and cleanup (as remote_race_test.exs)

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp assert_test_database! do
    expected = "sdr_agent_test" <> (System.get_env("MIX_TEST_PARTITION") || "")
    assert Mix.env() == :test
    assert Repo.config()[:database] == expected
    assert %{rows: [[^expected]]} = SQL.query!(Repo, "SELECT current_database()", [])
  end

  defp cleanup!(provenance_before) do
    assert_test_database!()
    tenant_ids = List.flatten(SQL.query!(Repo, "SELECT id FROM tenants", []).rows)
    Enum.each(tenant_ids, &cleanup_tenant!/1)
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    cleanup_provenance!(provenance_before)
  end

  defp cleanup_provenance!(before) do
    assert_test_database!()
    owned = provenance_ids() -- before

    if owned != [] do
      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM audit_events WHERE provenance_snapshot_id = ANY($1)",
                 [owned]
               )

      assert {:ok, _} =
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

                 assert %{num_rows: deleted} =
                          SQL.query!(
                            Repo,
                            "DELETE FROM provenance_snapshots WHERE id = ANY($1)",
                            [owned]
                          )

                 assert deleted == length(owned)
               end)
    end

    assert provenance_ids() == before, "a pre-existing provenance snapshot changed"
  end

  defp provenance_ids,
    do: List.flatten(SQL.query!(Repo, "SELECT id FROM provenance_snapshots ORDER BY id", []).rows)

  defp cleanup_tenant!(tenant_id) do
    tables = tenant_tables()

    assert {:ok, _} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
               subjects = subjects(tenant_id)
               SQL.query!(Repo, "DELETE FROM tokens WHERE subject = ANY($1)", [subjects])
               Enum.each(tables, &delete_tenant_rows!(&1, tenant_id))

               assert %{num_rows: 1} =
                        SQL.query!(Repo, "DELETE FROM tenants WHERE id = $1", [tenant_id])
             end)

    for table <- tables do
      assert %{rows: [[0]]} =
               SQL.query!(Repo, ~s[SELECT count(*) FROM "#{table}" WHERE tenant_id = $1], [
                 tenant_id
               ])
    end
  end

  defp subjects(tenant_id) do
    SQL.query!(Repo, "SELECT id FROM users WHERE tenant_id = $1", [tenant_id]).rows
    |> Enum.map(fn [id] ->
      AshAuthentication.user_to_subject(%SdrAgent.Accounts.User{id: Ecto.UUID.load!(id)})
    end)
  end

  defp tenant_tables do
    SQL.query!(
      Repo,
      "SELECT c.table_name FROM information_schema.columns c " <>
        "JOIN information_schema.tables t USING (table_schema, table_name) " <>
        "WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE' " <>
        "AND c.column_name = 'tenant_id' AND c.table_name <> 'tenants' ORDER BY c.table_name",
      []
    ).rows
    |> List.flatten()
  end

  defp delete_tenant_rows!(table, tenant_id),
    do: SQL.query!(Repo, ~s(DELETE FROM "#{table}" WHERE tenant_id = $1), [tenant_id])
end

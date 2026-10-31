defmodule SdrAgent.Agents.RemoteRaceTest do
  @moduledoc """
  S-B2 RED item 7 (entity/plan r2 6f0de674; r4 R1 lock order; Codex PASS
  ed0835d1 concurrency invariant), on independent database connections
  and transactions (no shared Sandbox owner).

  Contract specified here:

  - claim vs `Agents.admit_launch/3` on the same remote invocation, in both
    lock orders: exactly one sent transition, always by the claim; the
    local admit_launch returns `{:error, :remote_transport}` in both orders;
  - two competing claim requests of the one permitted worker (one active
    worker per binding is kept) with distinct nonces, on two connections,
    for one pending call: exactly one claimed, one sent transition; the
    loser returns `:none` and persists no claim and no nonce binding to
    that call;
  - complete vs the deadline expiry (a completion that arrives at or after
    result_deadline expires the call unknown), in both orders: exactly one
    terminal state, a result only when completed, exactly one terminal
    transition event.

  Ordering is forced by a holder that locks the run row (or the worker row)
  in its own transaction: the first waiter queued on that row lock proceeds
  first. Synchronization is message- and lock-wait-based; the only sleep is
  the bounded poll interval of the lock-wait observation. Participants are
  supervised, bounded and joined. Fixture rows are committed on real
  connections and removed on exit (this test's tenant rows and provenance
  snapshots only, D2). Synthetic data only; no model, no CLI.
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

  ## Holders and invariants

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

  defp sent_events(fx, invocation),
    do: F.subject_count(fx, "model.invocation.sent", invocation.id)

  ## Claim vs admit_launch

  for order <- [:claim_first, :admit_first] do
    test "claim vs admit_launch (#{order}): one sent transition, by the claim", ctx do
      %{token: token} = F.enrol!(ctx.fx)
      invocation = F.reserve!(ctx.fx)
      assert F.call_of(invocation.id), "no RemoteModelCall for the remote invocation"
      nonce = F.nonce()

      claim = fn ->
        ordinary!()
        F.claim(token, nonce)
      end

      admit = fn ->
        ordinary!()
        Agents.admit_launch(invocation.id, invocation.profile_id, actor: ctx.fx.agent)
      end

      {first, second} =
        if unquote(order) == :claim_first, do: {claim, admit}, else: {admit, claim}

      [r1, r2] = ordered(ctx, fn -> lock_run!(ctx.fx) end, [first, second])
      {claimed, admitted} = if unquote(order) == :claim_first, do: {r1, r2}, else: {r2, r1}

      assert match?({:ok, %{call_id: _}}, claimed), "claim: #{inspect(claimed)}"
      assert admitted == {:error, :remote_transport}, "admit_launch: #{inspect(admitted)}"
      assert F.invocation(invocation.id).status == :sent
      assert sent_events(ctx.fx, invocation) == 1
      assert F.call_of(invocation.id)["state"] == "claimed"
    end
  end

  ## Two competing claim requests

  test "two competing claims of one worker with distinct nonces: one claimed, the loser binds nothing",
       ctx do
    %{worker: worker, token: token} = F.enrol!(ctx.fx)
    invocation = F.reserve!(ctx.fx)
    call_id = F.load(F.call_of(invocation.id)["id"])
    n1 = F.nonce()
    n2 = F.nonce()

    results =
      ordered(ctx, fn -> lock_worker!(worker) end, [
        fn ->
          ordinary!()
          F.claim(token, n1)
        end,
        fn ->
          ordinary!()
          F.claim(token, n2)
        end
      ])

    winners = Enum.filter(results, &match?({:ok, %{call_id: _}}, &1))
    assert length(winners) == 1, "claims: #{inspect(results)}"
    assert Enum.count(results, &(&1 == {:ok, :none})) == 1, "claims: #{inspect(results)}"

    [{:ok, launch}] = winners
    assert launch.call_id == call_id
    loser = if hd(results) == {:ok, :none}, do: n1, else: n2

    bound =
      F.count(F.nonce_resource(), "claim_nonce = $1 AND call_id IS NOT NULL", [loser])

    assert bound == 0, "the losing nonce was bound to a call"
    assert F.call_row(call_id)["state"] == "claimed"
    assert F.load(F.call_row(call_id)["worker_id"]) == worker.id
    assert sent_events(ctx.fx, invocation) == 1
  end

  ## Complete vs the deadline expiry

  for order <- [:complete_first, :expiry_first] do
    test "complete vs expiry (#{order}): exactly one terminal state", ctx do
      %{token: token} = F.enrol!(ctx.fx)
      F.reserve!(ctx.fx)
      nonce = F.nonce()
      launch = F.claim!(token, nonce)
      deadline = F.ts(F.call_row(launch.call_id)["result_deadline"])
      bytes = F.transcript("race")

      in_time = fn ->
        ordinary!()
        F.complete(token, nonce, launch.call_id, launch.request_sha256, bytes)
      end

      late = fn ->
        ordinary!()
        Clock.freeze(DateTime.add(deadline, 1, :second))
        F.complete(token, nonce, launch.call_id, launch.request_sha256, bytes)
      end

      steps = if unquote(order) == :complete_first, do: [in_time, late], else: [late, in_time]
      results = ordered(ctx, fn -> lock_run!(ctx.fx) end, steps)
      kinds = Enum.map(results, &F.kind/1)
      state = F.call_row(launch.call_id)["state"]
      stored = F.count(F.result_resource(), "call_id = $1", [F.dump(launch.call_id)])

      terminal_events =
        F.subject_count(ctx.fx, "remote_call.completed", launch.call_id) +
          F.subject_count(ctx.fx, "remote_call.expired_unknown", launch.call_id)

      if unquote(order) == :complete_first do
        assert kinds == [:accepted, :duplicate_same], "kinds: #{inspect(results)}"
        assert {state, stored} == {"completed", 1}
      else
        assert kinds == [:late, :late], "kinds: #{inspect(results)}"
        assert {state, stored} == {"expired_unknown", 0}
      end

      assert terminal_events == 1
      assert length(F.receipts(launch.call_id)) == 2
    end
  end

  ## Participants

  # A holder takes `lock` in its own transaction; each step starts on its own
  # connection and is observed waiting before the next starts; the holder
  # then commits and the steps' results are returned in step order.
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

  # Waits until the participant's backend waits on any lock.
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

  ## Fixture database and cleanup (D2, as relocation_fence_race_test.exs)

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

  # The database held no tenant at setup, so every tenant now present is this
  # test's: its tenant rows (every table with tenant_id, the new remote-call
  # tables included) and its users' tokens; then only the provenance
  # snapshots this test created.
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
                            [
                              owned
                            ]
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

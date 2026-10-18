defmodule SdrAgent.SDR.TerminalSentRecoveryRaceTest do
  @moduledoc """
  L2 E1 under real concurrency (plan `notes/features/l2-e1-terminal-sent.org`
  items 15, 16c and 8b's failed read). Every participant works on its own
  non-sandboxed connection, reports its backend, and each ordering is proved
  by that participant's `pg_blocking_pids` naming the intended blocker, not
  by a database-wide count. Participants are supervised, unlinked, bounded
  and always joined (or killed and joined) before cleanup.

  `Agents.mark_terminal_run_sent_unknown/3` locks the run, then the run's
  `sent` rows. So an operator cancel holding the run goes first; a
  settlement already waiting on the run goes first; and a pass holding the
  run (waiting on a row) goes before a settlement queued behind it.

  The fixture is one synthetic tenant created here, in the exact partition
  database. Setup refuses to start over pre-existing tenant data, and
  cleanup deletes only that tenant's rows and its user's tokens. Global
  content-addressed provenance snapshots are kept (#178).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.Repo
  alias SdrAgent.SDR.StaleRunSweeper

  @t0 ~U[2026-10-20 12:00:00.000000Z]
  @bound 20_000

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    {:ok, tenant} = Audit.bootstrap(slug: "e1-race", name: "Synthetic E1 Race")
    admin = AuditCase.human(:admin, tenant)
    on_exit(fn -> with_connection(fn -> cleanup!(tenant, admin) end) end)
    on_exit(&Clock.unfreeze/0)
    supervisor = start_supervised!(Task.Supervisor)

    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    attrs = "race" |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"r":"race"}))
    Clock.freeze(@t0)
    {:ok, reserved} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, _} = Agents.admit_launch(reserved.id, :claude_cli_opus, actor: agent)
    sent = stored(reserved.id)
    Clock.freeze(DateTime.add(sent.sent_at, StaleRunSweeper.stale_after_seconds() + 1, :second))

    %{
      tenant: tenant,
      admin: admin,
      run: run,
      agent: agent,
      sent: sent,
      supervisor: supervisor
    }
  end

  ## The E1 entry points, asserted in the test process before any
  ## participant starts (a missing function fails the test, not a task).

  defp assert_e1_defined! do
    assert Code.ensure_loaded?(Agents) and
             function_exported?(Agents, :mark_terminal_run_sent_unknown, 3),
           "E1: Agents.mark_terminal_run_sent_unknown/3 is not defined"
  end

  defp assert_authority_defined! do
    assert Code.ensure_loaded?(Gate) and function_exported?(Gate, :reservation_authority, 1),
           "E1: Admission.Gate.reservation_authority/1 is not defined"
  end

  defp e1(run_id, actor) do
    Function.capture(Agents, :mark_terminal_run_sent_unknown, 3).(
      run_id,
      StaleRunSweeper.stale_after_seconds(),
      actor: actor
    )
  end

  defp authority(invocation),
    do: Function.capture(Gate, :reservation_authority, 1).(invocation)

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  ## Participants

  # Starts `fun` on its own connection; it first reports its backend pid.
  # Returns `{task, backend}`.
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

  # A participant that runs `lock` in a transaction, reports, holds until
  # `:go` (bounded), then runs `then` before commit.
  defp holder(ctx, tag, lock, then \\ fn -> :ok end) do
    parent = self()
    held = participant(ctx, tag, fn -> hold(parent, tag, lock, then) end)
    assert_receive {:held, ^tag}, @bound
    held
  end

  defp hold(parent, tag, lock, then) do
    Repo.transaction(fn ->
      lock.()
      send(parent, {:held, tag})

      receive do
        :go -> then.()
      after
        @bound -> Repo.rollback(:holder_timeout)
      end
    end)
  end

  defp release({task, _backend}), do: send(task.pid, :go)

  defp await({task, _backend}) do
    case Task.yield(task, @bound) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> flunk("participant did not finish: #{inspect(other)}")
    end
  end

  # Every participant is killed and joined, whatever the test's outcome.
  defp joined(participants, fun) do
    fun.()
  after
    Enum.each(participants, fn {task, _} -> Task.shutdown(task, :brutal_kill) end)
  end

  defp lock_run!(run_id),
    do: SQL.query!(Repo, "SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", [uuid(run_id)])

  defp lock_row!(id),
    do: SQL.query!(Repo, "SELECT id FROM model_invocations WHERE id = $1 FOR UPDATE", [uuid(id)])

  defp lock_audit!,
    do: SQL.query!(Repo, "LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE", [])

  defp backend, do: hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))

  # Waits until `waiter`'s backend is blocked by `blocker`'s backend.
  defp await_blocked(waiter, blocker, attempts \\ 400)

  defp await_blocked({_, waiter}, {_, blocker}, 0),
    do: flunk("backend #{waiter} was never blocked by #{blocker}")

  defp await_blocked({_, waiter} = w, {_, blocker} = b, attempts) do
    %{rows: [[blocked?]]} =
      SQL.query!(Repo, "SELECT $2::int = ANY(pg_blocking_pids($1::int))", [waiter, blocker])

    unless blocked? do
      Process.sleep(25)
      await_blocked(w, b, attempts - 1)
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  ## Orders

  test "an operator cancel holding the run: the pass waits, then normalizes", ctx do
    assert_e1_defined!()
    cancel = holder(ctx, :cancel, fn -> lock_run!(ctx.run.id) end, fn -> cancel!(ctx) end)

    joined([cancel], fn ->
      pass = participant(ctx, :pass, fn -> e1(ctx.run.id, ctx.agent) end)

      joined([pass], fn ->
        await_blocked(pass, cancel)
        release(cancel)
        assert {:ok, {:ok, _}} = await(cancel)
        assert await(pass) == {:ok, 1}, "E1: the pass converts once the run is terminal"
      end)
    end)

    assert stored(ctx.sent.id).status == :unknown
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a holder that leaves the run running: the pass finds it not terminal", ctx do
    assert_e1_defined!()
    hold = holder(ctx, :hold, fn -> lock_run!(ctx.run.id) end)

    joined([hold], fn ->
      pass = participant(ctx, :pass, fn -> e1(ctx.run.id, ctx.agent) end)

      joined([pass], fn ->
        await_blocked(pass, hold)
        release(hold)
        assert {:ok, :ok} = await(hold)
        assert await(pass) == {:error, :not_terminal}
      end)
    end)

    assert stored(ctx.sent.id).status == :sent
  end

  # 16f under real locks: a settlement already waiting on the cancelled
  # run (the facade's step after its re-read saw `sent`) goes first and gets
  # the existing refusal observed through the facade ("run is not
  # running"); the pass queued behind it then normalizes the row.
  test "a settlement queued on the run ahead of the pass: refused, then the pass", ctx do
    assert_e1_defined!()
    {:ok, _} = cancel!(ctx)
    hold = holder(ctx, :hold, fn -> lock_run!(ctx.run.id) end)

    joined([hold], fn ->
      settle = participant(ctx, :settle, fn -> complete(ctx) end)

      joined([settle], fn ->
        await_blocked(settle, hold)
        pass = participant(ctx, :pass, fn -> e1(ctx.run.id, ctx.agent) end)

        joined([pass], fn ->
          await_blocked(pass, hold)
          release(hold)
          assert {:ok, :ok} = await(hold)
          assert_status_refused(await(settle), "run is not running")
          assert await(pass) == {:ok, 1}, "E1: the pass normalizes after the refusal"
        end)
      end)
    end)

    assert_recovered(ctx)
  end

  # 16c: the pass holds the run (it waits on the `sent` row a holder has
  # locked) and a settlement with the already-read `sent` struct queues
  # behind the pass's run lock. The pass commits first; the settlement then
  # gets the observed stale-settle refusal ("invalid transition to
  # completed"). The facade itself is not driven here.
  test "a pass holding the run ahead of a settlement: normalized, then refused", ctx do
    assert_e1_defined!()
    {:ok, _} = cancel!(ctx)
    row = holder(ctx, :row, fn -> lock_row!(ctx.sent.id) end)

    joined([row], fn ->
      pass = participant(ctx, :pass, fn -> e1(ctx.run.id, ctx.agent) end)

      joined([pass], fn ->
        await_blocked(pass, row)
        settle = participant(ctx, :settle, fn -> complete(ctx) end)

        joined([settle], fn ->
          await_blocked(settle, pass)
          release(row)
          assert {:ok, :ok} = await(row)
          assert await(pass) == {:ok, 1}, "E1: the pass holding the run commits first"
          assert_status_refused(await(settle), "invalid transition to completed")
        end)
      end)
    end)

    assert_recovered(ctx)
  end

  # Plan 8b: a failed evidence read of a valid, bound row is :invalid, not
  # a raise. A holder takes `audit_events` exclusively; the reader is seen
  # blocked on it, and its bounded lock_timeout fails the read.
  test "a failed reservation-evidence read of a valid row is :invalid", ctx do
    assert_authority_defined!()
    lock = holder(ctx, :lock, &lock_audit!/0)

    joined([lock], fn ->
      read = participant(ctx, :read, fn -> bounded_read(ctx.sent) end)

      joined([read], fn ->
        await_blocked(read, lock)
        assert await(read) == :invalid, "E1: a failed evidence read fails closed"
        release(lock)
        assert {:ok, :ok} = await(lock)
      end)
    end)

    assert authority(ctx.sent) == :no_tuple
  end

  ## Helpers

  defp cancel!(ctx), do: Agents.cancel_run(ctx.run, actor: ctx.admin)

  defp complete(ctx),
    do: Agents.complete_model_invocation(ctx.sent, AgentsFixtures.completion(), actor: ctx.agent)

  defp bounded_read(invocation) do
    SQL.query!(Repo, "SET lock_timeout = '3s'", [])

    try do
      authority(invocation)
    after
      SQL.query!(Repo, "RESET lock_timeout", [])
    end
  end

  defp assert_status_refused(result, message) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result

    assert Enum.any?(
             errors,
             &match?(%Ash.Error.Changes.InvalidAttribute{field: :status, message: ^message}, &1)
           ),
           "expected the status refusal #{inspect(message)}, got #{inspect(errors)}"
  end

  defp assert_recovered(ctx) do
    row = stored(ctx.sent.id)
    assert {row.status, row.response_sha256} == {:unknown, nil}

    refute ModelResultRelease
           |> Ash.Query.filter(model_invocation_id == ^row.id)
           |> Ash.exists?(authorize?: false)
  end

  defp auditor(ctx), do: struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: ctx.tenant.id)

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  # The exact partition database, by configuration and by the server.
  defp assert_test_database! do
    expected = "sdr_agent_test" <> (System.get_env("MIX_TEST_PARTITION") || "")
    assert Mix.env() == :test
    assert Repo.config()[:database] == expected
    assert %{rows: [[^expected]]} = SQL.query!(Repo, "SELECT current_database()", [])
  end

  # Only this fixture's tenant rows and its user's tokens; never another
  # tenant's data and never global provenance snapshots.
  defp cleanup!(tenant, admin) do
    assert_test_database!()
    tenant_id = uuid(tenant.id)
    tables = tenant_tables()

    assert {:ok, _} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
               subject = AshAuthentication.user_to_subject(admin)
               SQL.query!(Repo, "DELETE FROM tokens WHERE subject = $1", [subject])
               Enum.each(tables, &delete_tenant_rows!(&1, tenant_id))

               assert %{num_rows: 1} =
                        SQL.query!(Repo, "DELETE FROM tenants WHERE id = $1", [tenant_id])
             end)

    for table <- tables do
      assert %{rows: [[0]]} =
               SQL.query!(Repo, "SELECT count(*) FROM \"#{table}\" WHERE tenant_id = $1", [
                 tenant_id
               ])
    end
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

defmodule SdrAgent.Agents.OrdinaryLaunchRaceTest do
  @moduledoc """
  L2 E3 (plan `notes/features/l2-e3-ordinary-calls.org`, PASS `e462d48`,
  clarifications 2 and 4 of Codex `cad33c66`): a failed recorded-authority
  read under the launch locks, in ordinary mode, on real connections.

  The existing contract is pinned honestly: the locked `Gate.admit_launch/3`
  read fails, the launch transaction rolls back and no committed refusal is
  promised; the pre-existing reservation stays `reserved`, never sent and
  never launched. Only after the failed read is observed is the table holder
  released; the facade-style fail of the reserved row then commits (charged,
  never launched). Participants are supervised, bounded and joined; the
  fixture is one owned synthetic tenant (the E1 race harness), provenance
  snapshots kept.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  @bound 20_000

  setup do
    AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    {:ok, tenant} = Audit.bootstrap(slug: "e3-race", name: "Synthetic E3 Race")
    admin = AuditCase.human(:admin, tenant)
    on_exit(fn -> with_connection(fn -> cleanup!(tenant, admin) end) end)
    supervisor = start_supervised!(Task.Supervisor)

    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    attrs = AgentsFixtures.claude_attrs("e3-race")

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs, actor: agent)
      end)

    %{
      tenant: tenant,
      admin: admin,
      run: run,
      agent: agent,
      reserved: reserved,
      supervisor: supervisor
    }
  end

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  # The launch, on its own connection, with a bounded lock wait; the
  # setting is reset before the connection is returned.
  defp bounded_launch(ctx) do
    SQL.query!(Repo, "SET lock_timeout = '3s'", [])

    try do
      AdmissionFixtures.admitting(fn ->
        Agents.admit_launch(ctx.reserved.id, :claude_cli_opus,
          actor: ctx.agent,
          ordinary_launch: true
        )
      end)
    rescue
      error -> {:raised, error}
    after
      SQL.query!(Repo, "RESET lock_timeout", [])
    end
  end

  defp lock_audit!,
    do: SQL.query!(Repo, "LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE", [])

  test "control: a failed locked evidence read rolls the launch back; the row stays reserved",
       ctx do
    lock = holder(ctx, :lock, &lock_audit!/0)

    joined([lock], fn ->
      launch = participant(ctx, :launch, fn -> bounded_launch(ctx) end)

      joined([launch], fn ->
        await_blocked(launch, lock)
        result = await(launch)

        assert match?({:raised, _}, result) or match?({:error, _}, result),
               "the failed read is an error, never a launch: #{inspect(result, limit: 4)}"

        refute match?({:ok, _}, result)

        assert inspect(result, limit: :infinity) =~ "lock_not_available" or
                 inspect(result, limit: :infinity) =~ "lock timeout",
               "the real lock timeout was observed: #{inspect(result, limit: 6)}"

        row = stored(ctx.reserved.id)
        assert {row.status, row.sent_at} == {:reserved, nil}, "rolled back: still reserved"

        # Only now is the holder released, before the facade-style fail.
        release(lock)
        assert {:ok, :ok} = await(lock)
      end)
    end)

    assert {:ok, failed} =
             Agents.fail_model_invocation(
               stored(ctx.reserved.id),
               %{error: %{"kind" => "launch_admission_failed"}},
               actor: ctx.agent
             )

    assert {failed.status, failed.sent_at} == {:failed, nil}
  end

  ## Participants (the E1 race harness)

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

  # An audited transaction, so a guarded call (the cancel) may run in it.
  defp hold(parent, tag, lock, then) do
    Audit.transaction(fn ->
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

  ## Fixture database and cleanup

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

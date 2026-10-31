defmodule SdrAgent.Prototype.HostedOwnerRaceTest do
  @moduledoc """
  S-B5a RED: independent-connection enrollment and one-use session races.
  Synthetic committed fixture only. A barrier starts bounded supervised
  participants; every task is joined before D2 own-row cleanup. No shared
  Sandbox connection and no model process.
  """
  use ExUnit.Case, async: false

  import SdrAgent.PrototypeCase, only: [loaded!: 1, call: 3]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.Repo

  @owner SdrAgent.Operations.HostedOwner
  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @bound 20_000

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    provenance_before = provenance_ids()
    on_exit(fn -> with_connection(fn -> cleanup!(provenance_before) end) end)
    supervisor = start_supervised!(Task.Supervisor)
    Map.put(H.activated!(), :supervisor, supervisor)
  end

  test "two independent enrollment requests create one active owner and one reviewer", ctx do
    loaded!(@owner)

    results =
      compete(ctx, fn index ->
        call(SdrAgent.Operations, :enrol_hosted_owner, [
          %{email: "racer-#{index}@example.test", display_name: "Synthetic racer"},
          H.console(ctx)
        ])
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    table = AshPostgres.DataLayer.Info.table(@owner)

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM \"#{table}\" WHERE status='active'", [])

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM users WHERE role='reviewer'", [])
  end

  test "two independent link consumers produce exactly one normal session", ctx do
    %{enrollment_token: link, user: user} = H.enrol!(ctx)
    results = compete(ctx, fn _ -> H.consume(link) end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    subject = AshAuthentication.user_to_subject(user)

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM tokens WHERE subject=$1 AND purpose='user'", [
               subject
             ])
  end

  test "worker control waiting at head rechecks owner after disable commits", ctx do
    assert function_exported?(SdrAgent.Operations, :set_mac_worker_intake, 3),
           "set_mac_worker_intake/3 is not exported"

    enrolled = H.enrol!(ctx)
    %{worker: worker} = SdrAgent.RemoteCallFixtures.enrol!(ctx.fx)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        with_connection(fn ->
          :ok = PrototypeFixtures.leave_runtime()
          :ok = PrototypeFixtures.put_live_identity(ctx.destination)

          SdrAgent.Audit.transaction(fn ->
            assert {:ok, _} = SdrAgent.Audit.Kernel.lock_head(ctx.fx.tenant.id)
            send(parent, :worker_head_held)

            receive do
              :disable_owner -> H.disable(ctx, enrolled.owner.id)
            after
              @bound -> flunk("disable barrier timed out")
            end
          end)
        end)
      end)

    try do
      assert_receive :worker_head_held, @bound

      control =
        Task.Supervisor.async_nolink(ctx.supervisor, fn ->
          with_connection(fn ->
            H.enter!(ctx)
            backend = hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))
            send(parent, {:worker_backend, backend})

            call(SdrAgent.Operations, :set_mac_worker_intake, [
              worker,
              :paused,
              [actor: enrolled.user]
            ])
          end)
        end)

      try do
        assert_receive {:worker_backend, backend}, @bound
        await_worker_waiting(backend)
        send(holder.pid, :disable_owner)
        assert {:ok, {:ok, {:ok, _}}} = Task.yield(holder, @bound)
        assert {:ok, {:error, %Ash.Error.Forbidden{}}} = Task.yield(control, @bound)

        assert %{rows: [["open"]]} =
                 SQL.query!(Repo, "SELECT intake FROM mac_workers WHERE id=$1", [
                   Ecto.UUID.dump!(worker.id)
                 ])

        assert %{rows: [[0]]} =
                 SQL.query!(
                   Repo,
                   "SELECT count(*) FROM audit_events WHERE event_type='mac_worker.intake_set'",
                   []
                 )
      after
        Task.shutdown(control, :brutal_kill)
      end
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  test "transcript waiting at head returns no bytes after owner disable commits", ctx do
    assert function_exported?(SdrAgent.Agents, :read_remote_transcript, 2),
           "read_remote_transcript/2 is not exported"

    admin = SdrAgent.AuditCase.human(:admin, ctx.fx.tenant)
    :ok = SdrAgent.AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = SdrAgent.AgentsFixtures.definition!(ctx.fx.tenant)
    agent = SdrAgent.Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    SdrAgent.AdmissionFixtures.admit_tuples!()
    grant = SdrAgent.AgentsFixtures.grant!(fx.tenant, %{}, admin)
    run = SdrAgent.PrototypeGateFixtures.run!(fx)
    fx = Map.merge(fx, %{grant: grant, run: run})
    f = SdrAgent.RemoteCallFixtures
    f.remote!()
    %{token: token} = f.enrol!(fx)
    f.reserve!(fx)
    nonce = f.nonce()
    launch = f.claim!(token, nonce)
    bytes = "private-transcript-head-race"

    assert f.kind(f.complete(token, nonce, launch.call_id, launch.request_sha256, bytes)) ==
             :accepted

    enrolled = H.enrol!(ctx)
    parent = self()
    before = SQL.query!(Repo, "SELECT count(*) FROM audit_accesses", []).rows

    holder =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        with_connection(fn ->
          :ok = PrototypeFixtures.leave_runtime()
          :ok = PrototypeFixtures.put_live_identity(ctx.destination)

          SdrAgent.Audit.transaction(fn ->
            assert {:ok, _} = SdrAgent.Audit.Kernel.lock_head(ctx.fx.tenant.id)
            backend = hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))
            send(parent, {:transcript_head_held, backend})

            receive do
              :disable_owner -> H.disable(ctx, enrolled.owner.id)
            after
              @bound -> flunk("transcript disable barrier timed out")
            end
          end)
        end)
      end)

    try do
      assert_receive {:transcript_head_held, holder_backend}, @bound

      reader =
        Task.Supervisor.async_nolink(ctx.supervisor, fn ->
          with_connection(fn ->
            H.enter!(ctx)
            backend = hd(hd(SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows))
            send(parent, {:transcript_backend, backend})

            call(SdrAgent.Agents, :read_remote_transcript, [
              launch.call_id,
              [actor: enrolled.user]
            ])
          end)
        end)

      try do
        assert_receive {:transcript_backend, backend}, @bound
        await_head_holder(backend, holder_backend)
        send(holder.pid, :disable_owner)
        assert {:ok, {:ok, {:ok, _}}} = Task.yield(holder, @bound)
        assert {:ok, {:error, %Ash.Error.Forbidden{}} = refused} = Task.yield(reader, @bound)
        refute inspect(refused) =~ bytes
        assert SQL.query!(Repo, "SELECT count(*) FROM audit_accesses", []).rows == before
      after
        Task.shutdown(reader, :brutal_kill)
      end
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  defp await_head_holder(backend, holder, attempts \\ 400)

  defp await_head_holder(_backend, _holder, 0),
    do: flunk("reader never waited on exact head holder")

  defp await_head_holder(backend, holder, attempts) do
    %{rows: [[waiting?]]} =
      SQL.query!(Repo, "SELECT $2::int = ANY(pg_blocking_pids($1::int))", [backend, holder])

    unless waiting? do
      Process.sleep(25)
      await_head_holder(backend, holder, attempts - 1)
    end
  end

  defp await_worker_waiting(backend, attempts \\ 400)
  defp await_worker_waiting(_backend, 0), do: flunk("worker control never waited at head")

  defp await_worker_waiting(backend, attempts) do
    %{rows: [[waiting?]]} =
      SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1::int)) > 0", [backend])

    unless waiting? do
      Process.sleep(25)
      await_worker_waiting(backend, attempts - 1)
    end
  end

  defp compete(ctx, action) do
    parent = self()

    tasks = Enum.map(1..2, &participant(ctx, &1, parent, action))

    try do
      for task <- tasks do
        pid = task.pid
        assert_receive {:ready, ^pid}, @bound
      end

      Enum.each(tasks, &send(&1.pid, :go))

      Enum.map(tasks, fn task ->
        case Task.yield(task, @bound) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          other -> flunk("participant did not finish: #{inspect(other)}")
        end
      end)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp participant(ctx, index, parent, action) do
    Task.Supervisor.async_nolink(ctx.supervisor, fn ->
      with_connection(fn -> ready_and_run(ctx, index, parent, action) end)
    end)
  end

  defp ready_and_run(ctx, index, parent, action) do
    assert :ok = PrototypeFixtures.leave_runtime()
    assert :ok = PrototypeFixtures.put_live_identity(ctx.destination)
    send(parent, {:ready, self()})

    receive do
      :go -> action.(index)
    after
      @bound -> flunk("participant start deadline")
    end
  end

  # D2 cleanup below is copied from the reviewed relocation fence race.
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

  # The database held no tenant at setup, so every tenant now present is
  # this test's: its tenant rows, its users' tokens and its relocation
  # chain; then only the provenance snapshots this test created. Never
  # signing keys or a pre-existing provenance snapshot.
  defp cleanup!(provenance_before) do
    assert_test_database!()
    tenant_ids = List.flatten(SQL.query!(Repo, "SELECT id FROM tenants", []).rows)
    Enum.each(tenant_ids, &cleanup_tenant!/1)
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    cleanup_provenance!(provenance_before)
  end

  # D2 (Codex 005940Z): on the exact disposable test database (asserted),
  # after every participant is joined (on_exit runs once the test process
  # and its supervised tasks have exited; this async: false test is the
  # only writer), the snapshots present now and absent at setup are this
  # fixture's. Their referring rows (audit_events, tenant rows) were
  # removed above; only those ids are deleted, by bound parameter. Every
  # pre-existing row is preserved and no owned row is left.
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
               delete_chain!(tenant_id)
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

  # The relocation chain of the tenant's bindings, whether or not its
  # tables carry tenant_id (absent before GREEN).
  defp delete_chain!(tenant_id) do
    if Code.ensure_loaded?(@relocation) and Code.ensure_loaded?(@event) do
      relocations = AshPostgres.DataLayer.Info.table(@relocation)
      events = AshPostgres.DataLayer.Info.table(@event)

      ids =
        ~s(SELECT r.id FROM "#{relocations}" r JOIN prototype_database_bindings b ) <>
          "ON b.id = r.binding_id WHERE b.tenant_id = $1"

      SQL.query!(Repo, ~s[DELETE FROM "#{events}" WHERE relocation_id IN (#{ids})], [tenant_id])
      SQL.query!(Repo, ~s[DELETE FROM "#{relocations}" WHERE id IN (#{ids})], [tenant_id])
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

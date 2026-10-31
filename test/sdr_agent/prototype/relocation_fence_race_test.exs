defmodule SdrAgent.Prototype.RelocationFenceRaceTest do
  @moduledoc """
  S-B1 RED r2 (ADR-0024 decision 1; plan R2 "Final fence serialization";
  Codex review 230957Z must_fix 2): the head lock serializes the owner-run
  `fenced` append against a concurrent spending writer, on independent
  database connections and transactions (no shared Sandbox owner).

  Contract specified here:

  - writer A takes `SdrAgent.Audit.Kernel.lock_head/1` in its own
    transaction and holds it; the owner-run `fenced` append (the
    `:relocation` kernel marker, `RelocationEvent :append`) is then blocked
    by A's backend (observed with `pg_blocking_pids`); A reserves through
    `SdrAgent.Agents.reserve_model_invocation/3` and commits; only then
    does the fence commit;
  - (a) A's reservation and its audit event are committed and visible
    together with the `fenced` event in one repeatable-read snapshot taken
    after the fence commit (the snapshot a dump would read);
  - (b) a writer B that starts after the fence commit is refused with
    `{:error, :relocation_fenced}` and writes no invocation and no audit
    event.

  Synchronization is message- and lock-wait-based; the only sleep is the
  bounded poll interval of the lock-wait observation. Participants are
  supervised, bounded and joined. The fixture is S1's real provisioning
  (`SdrAgent.PrototypeGateFixtures.prototype!/1`), committed on real
  connections and removed on exit (this test's tenant rows only).
  Synthetic `.test` data only; no provider call.
  """
  use ExUnit.Case, async: false

  import SdrAgent.AuditCase, only: [events: 1]
  import SdrAgent.PrototypeCase, only: [loaded!: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Repo

  @bound 20_000
  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    on_exit(fn -> with_connection(&cleanup!/0) end)
    supervisor = start_supervised!(Task.Supervisor)

    fx = G.prototype!()
    run = G.run!(fx)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    %{fx: fx, run: run, original: original, destination: destination, supervisor: supervisor}
  end

  ## Owner-run chain writes

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  # The calling process in ordinary runtime at the source identity.
  defp as_owner!(ctx) do
    assert PrototypeFixtures.leave_runtime() == :ok
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
  end

  # The calling process in prototype runtime at the source identity.
  defp as_writer!(ctx) do
    G.enter!(ctx.fx)
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
  end

  defp relocation!(ctx) do
    loaded!(@relocation)

    result =
      @relocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          binding_id: ctx.fx.binding.id,
          relocation_seq: 1,
          from_identity: ctx.original,
          to_identity: ctx.destination
        },
        owner(ctx.fx)
      )
      |> Ash.create()

    assert match?({:ok, %{id: _}}, result), "prerequisite: relocation create: #{inspect(result)}"
    {:ok, relocation} = result
    relocation
  end

  defp append(ctx, relocation, kind) do
    loaded!(@event)

    @event
    |> Ash.Changeset.for_create(
      :append,
      %{relocation_id: relocation.id, kind: kind},
      owner(ctx.fx)
    )
    |> Ash.create()
  end

  defp append!(ctx, relocation, kind) do
    result = append(ctx, relocation, kind)
    assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    :ok
  end

  # The fence append on its own connection, with a bounded lock wait.
  defp fence(ctx, relocation) do
    as_owner!(ctx)
    SQL.query!(Repo, "SET lock_timeout = '15s'", [])

    try do
      append(ctx, relocation, :fenced)
    rescue
      error -> {:raised, error}
    after
      SQL.query!(Repo, "RESET lock_timeout", [])
    end
  end

  # Writer A's reservation inside its head-locked transaction; a refusal
  # rolls A back so the transaction's result is the refusal.
  defp reserve_or_rollback(ctx) do
    case G.reserve(ctx.fx, ctx.run) do
      {:ok, %ModelInvocation{} = invocation} -> invocation
      other -> Repo.rollback({:reserve, other})
    end
  end

  defp lock_head!(ctx) do
    assert {:ok, %{}} = AuditKernel.lock_head(ctx.fx.tenant.id)
  end

  defp effects(ctx), do: {G.invocations(ctx.fx), length(events(ctx.fx.tenant))}

  ## The race

  test "a writer holding the head lock commits before the fence; a later writer is refused",
       ctx do
    as_owner!(ctx)
    relocation = relocation!(ctx)
    append!(ctx, relocation, :planned)
    append!(ctx, relocation, :writers_stopped)

    writer_a =
      holder(ctx, :writer_a, fn -> as_writer!(ctx) end, fn -> lock_head!(ctx) end, fn ->
        reserve_or_rollback(ctx)
      end)

    joined([writer_a], fn ->
      fenced = participant(ctx, :fence, fn -> fence(ctx, relocation) end)

      joined([fenced], fn ->
        await_blocked(fenced, writer_a)
        release(writer_a)

        a = await(writer_a)
        assert match?({:ok, %ModelInvocation{}}, a), "writer A before the fence: #{inspect(a)}"
        {:ok, invocation} = a

        f = await(fenced)
        assert match?({:ok, %{kind: :fenced}}, f), "the fence after writer A: #{inspect(f)}"

        # (a) A's write is in the snapshot a dump taken after the fence reads.
        assert dump_view(invocation, relocation) == %{invocation: 1, reserved: 1, fenced: 1}
      end)
    end)

    # (b) A writer that starts after the fence commit is refused.
    before = effects(ctx)

    writer_b =
      participant(ctx, :writer_b, fn ->
        as_writer!(ctx)
        G.reserve(ctx.fx, ctx.run)
      end)

    joined([writer_b], fn ->
      b = await(writer_b)
      assert b == {:error, :relocation_fenced}, "writer B after the fence: #{inspect(b)}"
    end)

    assert effects(ctx) == before, "the refused writer B wrote an invocation or audit event"
  end

  # One read-only repeatable-read snapshot after the fence commit: A's row,
  # A's reserved audit event and the fenced event, counted together.
  defp dump_view(invocation, relocation) do
    invocations = AshPostgres.DataLayer.Info.table(ModelInvocation)
    events = AshPostgres.DataLayer.Info.table(@event)
    id = uuid(invocation.id)

    {:ok, view} =
      Repo.transaction(fn ->
        SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

        %{
          invocation: scalar(~s[SELECT count(*) FROM "#{invocations}" WHERE id = $1], [id]),
          reserved:
            scalar(
              "SELECT count(*) FROM audit_events WHERE subject_id = $1 " <>
                "AND event_type = 'model.invocation.reserved'",
              [invocation.id]
            ),
          fenced:
            scalar(
              ~s[SELECT count(*) FROM "#{events}" WHERE relocation_id = $1 ] <>
                "AND kind::text = 'fenced'",
              [uuid(relocation.id)]
            )
        }
      end)

    view
  end

  defp scalar(sql, params) do
    %{rows: [[n]]} = SQL.query!(Repo, sql, params)
    n
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

  # A participant that runs `prepare` outside any transaction, then `lock`
  # in an audited transaction, reports, holds until `:go` (bounded), then
  # runs `then` before commit.
  defp holder(ctx, tag, prepare, lock, then) do
    parent = self()

    held =
      participant(ctx, tag, fn ->
        prepare.()
        hold(parent, tag, lock, then)
      end)

    assert_receive {:held, ^tag}, @bound
    held
  end

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

  # The database held no tenant at setup, so every tenant now present is
  # this test's: its tenant rows, its users' tokens and its relocation
  # chain. Never global provenance snapshots or signing keys.
  defp cleanup! do
    assert_test_database!()
    tenant_ids = List.flatten(SQL.query!(Repo, "SELECT id FROM tenants", []).rows)
    Enum.each(tenant_ids, &cleanup_tenant!/1)
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
  end

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

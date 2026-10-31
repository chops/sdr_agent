defmodule SdrAgent.Prototype.RelocationPositionRaceTest do
  @moduledoc """
  S-B1 RED r5 M3 (corrective r3b, entity PASS bbb5c558; Codex GREEN review
  85b05b45 M3): two owner-run appends contending for the head lock on
  independent database connections and transactions (no shared Sandbox
  owner) are ordered by their serialized `position`, never by a timestamp
  sampled before the lock.

  Contract specified here:

  - successful pair: after `planned`, owner A takes
    `SdrAgent.Audit.Kernel.lock_head/1` in its own transaction and holds it;
    owner B starts the `fenced` append and blocks on A's backend (observed
    with `pg_blocking_pids`); A appends `writers_stopped` and commits; B
    then acquires the lock and appends `fenced`. The positions are 2 (A) and
    3 (B), pairwise distinct, and the read order
    (`SdrAgent.Prototype.Relocation.chain/2`) is
    [planned, writers_stopped, fenced]. Each participant freezes its own
    test Clock so that A's `recorded_at` is LATER than B's: a
    timestamp-sorted read fails;
  - waiting post-fence abort (M2, kept): after `writers_stopped`, A holds
    the lock; B starts `aborted` and blocks; A appends `fenced` and commits;
    B then sees `fenced` and is refused with `Ash.Error.Invalid`, writing
    no row; the source stays fenced.

  Synchronization is message- and lock-wait-based; the only sleep is the
  bounded poll interval of the lock-wait observation. Participants are
  supervised, bounded and joined. The fixture is S1's real provisioning
  (`SdrAgent.PrototypeGateFixtures.prototype!/1`), committed on real
  connections and removed on exit with the D2 own-row cleanup of
  `relocation_fence_race_test.exs` (this test's tenant rows and only the
  provenance snapshots it created). Owner writes in ordinary runtime.
  Synthetic `.test` data only; no provider call.
  """
  use ExUnit.Case, async: false

  import SdrAgent.PrototypeCase, only: [loaded!: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Clock
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Repo

  @bound 20_000
  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @authority SdrAgent.Prototype.CurrentAuthority

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    assert_test_database!()
    assert %{rows: [[0]]} = SQL.query!(Repo, "SELECT count(*) FROM tenants", [])
    # D2: the provenance snapshots present before any fixture write.
    provenance_before = provenance_ids()
    on_exit(fn -> with_connection(fn -> cleanup!(provenance_before) end) end)
    supervisor = start_supervised!(Task.Supervisor)

    fx = G.prototype!()
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    # B's frozen time, then A's one hour later (both after `planned`).
    early = DateTime.add(Clock.utc_now(), 3_600, :second)
    late = DateTime.add(early, 3_600, :second)

    %{
      fx: fx,
      original: original,
      destination: destination,
      supervisor: supervisor,
      early: early,
      late: late
    }
  end

  ## Owner-run chain writes

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  # The calling process in ordinary runtime at the source identity, its
  # clock frozen at `at` (nil: the system clock).
  defp as_owner!(ctx, at \\ nil) do
    assert PrototypeFixtures.leave_runtime() == :ok
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
    if at, do: assert(Clock.freeze(at) == :ok)
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

  # Owner B's append on its own connection at the EARLY clock, with a
  # bounded lock wait.
  defp waiting(ctx, relocation, kind) do
    as_owner!(ctx, ctx.early)
    SQL.query!(Repo, "SET lock_timeout = '15s'", [])

    try do
      append(ctx, relocation, kind)
    rescue
      error -> {:raised, error}
    after
      SQL.query!(Repo, "RESET lock_timeout", [])
    end
  end

  # Owner A's append inside its head-locked transaction at the LATE clock;
  # a refusal rolls A back so the transaction's result is the refusal.
  defp append_or_rollback(ctx, relocation, kind) do
    case append(ctx, relocation, kind) do
      {:ok, event} -> event
      other -> Repo.rollback({:append, kind, other})
    end
  end

  defp lock_head!(ctx) do
    assert {:ok, %{}} = AuditKernel.lock_head(ctx.fx.tenant.id)
  end

  defp holder_a(ctx, relocation, kind) do
    holder(ctx, :owner_a, fn -> as_owner!(ctx, ctx.late) end, fn -> lock_head!(ctx) end, fn ->
      append_or_rollback(ctx, relocation, kind)
    end)
  end

  defp chain_kinds!(ctx) do
    result = Kernel.apply(@relocation, :chain, [ctx.fx.binding.id, ctx.fx.tenant.id])
    assert match?({:ok, [_]}, result), "Relocation.chain/2: #{inspect(result)}"
    {:ok, [relocation]} = result
    {Enum.map(relocation.events, & &1.kind), relocation}
  end

  defp kind_rows(relocation, kind) do
    events = AshPostgres.DataLayer.Info.table(@event)

    scalar(
      ~s[SELECT count(*) FROM "#{events}" WHERE relocation_id = $1 AND kind::text = $2],
      [uuid(relocation.id), to_string(kind)]
    )
  end

  defp position!(event) do
    assert Ash.Resource.Info.attribute(@event, :position), "RelocationEvent has no position"
    Map.get(event, :position)
  end

  ## The races

  test "two successful appends are ordered by serialized position, not recorded_at", ctx do
    as_owner!(ctx)
    relocation = relocation!(ctx)
    append!(ctx, relocation, :planned)

    owner_a = holder_a(ctx, relocation, :writers_stopped)

    joined([owner_a], fn ->
      owner_b = participant(ctx, :owner_b, fn -> waiting(ctx, relocation, :fenced) end)

      joined([owner_b], fn ->
        await_blocked(owner_b, owner_a)
        release(owner_a)

        a = await(owner_a)
        assert match?({:ok, %{kind: :writers_stopped}}, a), "owner A: #{inspect(a)}"
        {:ok, a} = a

        b = await(owner_b)
        assert match?({:ok, %{kind: :fenced}}, b), "owner B after A: #{inspect(b)}"
        {:ok, b} = b

        # Prerequisite: A's recorded_at is LATER than B's.
        assert DateTime.compare(a.recorded_at, b.recorded_at) == :gt,
               "the reversed clock: A #{inspect(a.recorded_at)}, B #{inspect(b.recorded_at)}"

        {kinds, _relocation} = chain_kinds!(ctx)

        assert kinds == [:planned, :writers_stopped, :fenced],
               "read order after the race: #{inspect(kinds)}"

        assert {position!(a), position!(b)} == {2, 3}
        assert position!(a) != position!(b)
      end)
    end)
  end

  test "an abort waiting on the head lock is refused once the fence commits", ctx do
    as_owner!(ctx)
    relocation = relocation!(ctx)
    append!(ctx, relocation, :planned)
    append!(ctx, relocation, :writers_stopped)

    owner_a = holder_a(ctx, relocation, :fenced)

    joined([owner_a], fn ->
      owner_b = participant(ctx, :owner_b, fn -> waiting(ctx, relocation, :aborted) end)

      joined([owner_b], fn ->
        await_blocked(owner_b, owner_a)
        release(owner_a)

        a = await(owner_a)
        assert match?({:ok, %{kind: :fenced}}, a), "owner A's fence: #{inspect(a)}"

        b = await(owner_b)

        assert match?({:error, %Ash.Error.Invalid{}}, b),
               "the waiting abort after the fence: expected Invalid, got #{inspect(b)}"
      end)
    end)

    assert kind_rows(relocation, :aborted) == 0, "the refused abort wrote a row"
    {kinds, chain_relocation} = chain_kinds!(ctx)
    assert kinds == [:planned, :writers_stopped, :fenced]
    assert Kernel.apply(@authority, :fenced?, [[chain_relocation], ctx.original])
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

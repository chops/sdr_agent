defmodule SdrAgent.Prototype.RelocationLedgerTest do
  @moduledoc """
  S-B1 RED r5 M1 (corrective r3b, entity PASS bbb5c558; Codex GREEN review
  85b05b45 M1): every relocation row is covered by the tenant's hash-chained
  ledger through the UNCHANGED `SdrAgent.Audit.Changes.AppendEvent`
  after_action, and the owner-run writes are refused in prototype runtime.

  Contract specified here:

  - `Relocation :create` appends exactly one AuditEvent
    `prototype.relocation.created` and each successful
    `RelocationEvent :append` (every kind) exactly one
    `prototype.relocation.event_appended`, both category `:domain_change`,
    in the same transaction. Each event's subject is the stored row
    (`subject_resource`, `subject_id`); its payload carries the action and
    the full after-image (created: binding_id, relocation_seq,
    from_identity, to_identity; appended: relocation_id, kind, position,
    identity, recorded_by, recorded_at) and `record_sha256` equal to
    `SdrAgent.Audit.RecordHash.hex/1` of the stored row. Counts are by
    event_type and subject, never all tenant events;
  - an injected failure of the event append (a sandbox-local trigger on
    `audit_events`, the existing pattern of `launch_gate_test.exs` and
    `finish_calibration_test.exs`) rolls the action back: no row, no event,
    no chain-head advance and no new provenance snapshot;
  - an insert failure of the row (a sandbox-local trigger on the row's
    table) leaves no event and no head advance;
  - the relocation policy is a conjunction, marked kernel AND ordinary
    runtime: in prototype runtime the marked kernel request is
    `Ash.Error.Forbidden` for both actions and writes nothing; unmarked
    callers stay Forbidden in either runtime
    (`relocation_chain_test.exs`); the marked ordinary request is allowed.

  Owner writes run in ordinary runtime (`relocation_fence_test.exs:82-85`,
  `PrototypeFixtures.leave_runtime/0`). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Prototype.Checks.KernelMarker

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @created "prototype.relocation.created"
  @appended "prototype.relocation.event_appended"
  @destination_kinds [:restored, :activated, :destination_disabled]

  setup do
    fx = bound!(enter_runtime: false)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    %{fx: fx, original: original, destination: destination}
  end

  ## Helpers

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  defp create(ctx, seq, from, to, opts) do
    loaded!(@relocation)

    safely(fn ->
      @relocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          binding_id: ctx.fx.binding.id,
          relocation_seq: seq,
          from_identity: from,
          to_identity: to
        },
        opts
      )
      |> Ash.create()
    end)
  end

  defp append(relocation, kind, opts) do
    loaded!(@event)

    safely(fn ->
      @event
      |> Ash.Changeset.for_create(:append, %{relocation_id: relocation.id, kind: kind}, opts)
      |> Ash.create()
    end)
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  defp relocation!(ctx, seq \\ 1, from \\ nil, to \\ nil) do
    from = from || ctx.original
    to = to || ctx.destination
    assert PrototypeFixtures.put_live_identity(from) == :ok
    result = create(ctx, seq, from, to, owner(ctx.fx))
    assert match?({:ok, %{id: _}}, result), "prerequisite: relocation create: #{inspect(result)}"
    {:ok, relocation} = result
    relocation
  end

  defp at_identity!(relocation, kind) do
    identity =
      if kind in @destination_kinds,
        do: ident(relocation.to_identity),
        else: ident(relocation.from_identity)

    assert PrototypeFixtures.put_live_identity(identity) == :ok
  end

  defp append!(ctx, relocation, kind) do
    at_identity!(relocation, kind)
    result = append(relocation, kind, owner(ctx.fx))
    assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    {:ok, event} = result
    event
  end

  defp ident(x),
    do: %{
      database: Map.get(x, :database),
      database_oid: Map.get(x, :database_oid),
      system_identifier: Map.get(x, :system_identifier)
    }

  # The identity as the jsonb payload decodes it.
  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp table(resource) do
    loaded!(resource)
    AshPostgres.DataLayer.Info.table(resource)
  end

  defp count(resource) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table(resource)}", [])
    n
  end

  # Ledger events of one type for one subject row (never all tenant events).
  defp subject_count(fx, type, subject_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND subject_id = $3",
        [Ecto.UUID.dump!(fx.tenant.id), type, to_string(subject_id)]
      )

    n
  end

  # Ledger events of one type correlated by an after-image field.
  defp correlated_count(fx, type, key, value) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND payload -> 'changes' ->> $3 = $4",
        [Ecto.UUID.dump!(fx.tenant.id), type, key, to_string(value)]
      )

    n
  end

  defp type_count(fx, type) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
        [Ecto.UUID.dump!(fx.tenant.id), type]
      )

    n
  end

  defp head(fx) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT last_sequence, last_event_hash FROM audit_chain_heads WHERE tenant_id = $1",
        [Ecto.UUID.dump!(fx.tenant.id)]
      )

    row
  end

  defp provenance_count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM provenance_snapshots", [])
    n
  end

  defp state(ctx, resource), do: {count(resource), head(ctx.fx), provenance_count()}

  defp the_event!(fx, type, subject_id) do
    found =
      Enum.filter(events_of_type(fx.tenant, type), &(&1.subject_id == to_string(subject_id)))

    assert match?([_one], found), "#{type} events for #{subject_id}: #{inspect(found)}"
    hd(found)
  end

  defp stored(resource, id, fx), do: Ash.get!(resource, id, AuditKernel.opts(fx.tenant.id))

  # A sandbox-local BEFORE INSERT trigger that raises on `table` (for
  # `audit_events`, only for `event_type`); rolled back with the test.
  defp inject_failure!(table, event_type \\ nil) do
    condition =
      if event_type,
        do:
          "IF NEW.event_type = '#{event_type}' THEN RAISE EXCEPTION 'injected failure'; END IF;",
        else: "RAISE EXCEPTION 'injected failure';"

    Repo.query!(
      """
      CREATE FUNCTION pg_temp.sdr_test_relocation_fault() RETURNS trigger AS $$
      BEGIN
        #{condition}
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """,
      []
    )

    Repo.query!(
      "CREATE TRIGGER sdr_test_relocation_fault BEFORE INSERT ON \"#{table}\" " <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_relocation_fault()",
      []
    )
  end

  ## M1: one ledger event per row

  describe "Relocation :create appends exactly one prototype.relocation.created" do
    test "its subject, after-image and record_sha256 are the stored row's", ctx do
      relocation = relocation!(ctx)

      assert subject_count(ctx.fx, @created, relocation.id) == 1,
             "expected exactly one #{@created} event for the created relocation"

      event = the_event!(ctx.fx, @created, relocation.id)
      row = stored(@relocation, relocation.id, ctx.fx)

      assert event.category == :domain_change
      assert event.subject_resource == inspect(@relocation)
      assert event.subject_id == to_string(row.id)
      assert event.payload["action"] == "create"

      changes = event.payload["changes"]
      assert is_map(changes), "payload has no after-image: #{inspect(event.payload)}"
      assert changes["binding_id"] == ctx.fx.binding.id
      assert changes["relocation_seq"] == 1
      assert keyed(changes["from_identity"]) == json(ctx.original)
      assert keyed(changes["to_identity"]) == json(ctx.destination)

      assert event.payload["record_sha256"] == RecordHash.hex(row)
    end
  end

  describe "each successful RelocationEvent kind appends exactly one event_appended" do
    test "all seven kinds, each against its stored row", ctx do
      first = relocation!(ctx, 1)

      main =
        for kind <- [:planned, :writers_stopped, :fenced, :restored, :activated],
            do: {kind, append!(ctx, first, kind)}

      back = relocation!(ctx, 2, ctx.destination, ctx.original)

      disabled =
        for kind <- [:planned, :writers_stopped, :fenced, :restored, :destination_disabled],
            do: {kind, append!(ctx, back, kind)}

      third = relocation!(ctx, 3, ctx.destination, ctx.original)
      aborted = for kind <- [:planned, :aborted], do: {kind, append!(ctx, third, kind)}

      appended = main ++ disabled ++ aborted
      kinds = appended |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert kinds == Enum.sort(SdrAgent.Prototype.RelocationEvent.kinds())

      for {kind, written} <- appended do
        assert subject_count(ctx.fx, @appended, written.id) == 1,
               "expected exactly one #{@appended} event for the #{kind} row"

        event = the_event!(ctx.fx, @appended, written.id)
        row = stored(@event, written.id, ctx.fx)

        assert event.category == :domain_change
        assert event.subject_resource == inspect(@event)
        assert event.payload["action"] == "append"

        changes = event.payload["changes"]
        assert is_map(changes), "#{kind}: payload has no after-image: #{inspect(event.payload)}"

        for key <- ~w(relocation_id kind position identity recorded_by recorded_at) do
          assert Map.has_key?(changes, key),
                 "#{kind}: after-image lacks #{key}: #{inspect(changes)}"
        end

        assert changes["relocation_id"] == row.relocation_id
        assert changes["kind"] == to_string(kind)
        assert changes["position"] == Map.get(row, :position)
        assert changes["recorded_by"] == "kernel:relocation"
        assert keyed(changes["identity"]) == json(ident(row.identity))
        assert event.payload["record_sha256"] == RecordHash.hex(row)
      end

      assert type_count(ctx.fx, @appended) == length(appended)
      assert type_count(ctx.fx, @created) == 3
    end
  end

  # The three identity keys of a decoded payload identity.
  defp keyed(map) when is_map(map), do: Map.take(map, ~w(database database_oid system_identifier))
  defp keyed(other), do: other

  ## M1: rollback

  describe "an injected failure of the event append rolls the action back" do
    test "Relocation :create: no row, no event, no head or provenance advance", ctx do
      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      inject_failure!("audit_events", @created)
      before = state(ctx, @relocation)

      result = create(ctx, 1, ctx.original, ctx.destination, owner(ctx.fx))

      refute match?({:ok, _}, result),
             "the create succeeded although its #{@created} append failed: #{inspect(result)}"

      assert state(ctx, @relocation) == before, "a row, head or provenance change survived"
      assert type_count(ctx.fx, @created) == 0
    end

    test "RelocationEvent :append: no row, no event, no head or provenance advance", ctx do
      relocation = relocation!(ctx)
      inject_failure!("audit_events", @appended)
      at_identity!(relocation, :planned)
      before = state(ctx, @event)

      result = append(relocation, :planned, owner(ctx.fx))

      refute match?({:ok, _}, result),
             "the append succeeded although its #{@appended} append failed: #{inspect(result)}"

      assert state(ctx, @event) == before, "a row, head or provenance change survived"
      assert correlated_count(ctx.fx, @appended, "relocation_id", relocation.id) == 0
    end
  end

  describe "an insert failure of the row leaves no event" do
    test "Relocation :create", ctx do
      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      inject_failure!(table(@relocation))
      before = {head(ctx.fx), type_count(ctx.fx, @created)}

      result = create(ctx, 1, ctx.original, ctx.destination, owner(ctx.fx))
      refute match?({:ok, _}, result), "the create succeeded: #{inspect(result)}"
      assert {head(ctx.fx), type_count(ctx.fx, @created)} == before
      assert count(@relocation) == 0
    end

    test "RelocationEvent :append", ctx do
      relocation = relocation!(ctx)
      inject_failure!(table(@event))
      at_identity!(relocation, :planned)
      before = {head(ctx.fx), correlated_count(ctx.fx, @appended, "relocation_id", relocation.id)}

      result = append(relocation, :planned, owner(ctx.fx))
      refute match?({:ok, _}, result), "the append succeeded: #{inspect(result)}"

      assert {head(ctx.fx), correlated_count(ctx.fx, @appended, "relocation_id", relocation.id)} ==
               before

      assert count(@event) == 0
    end
  end

  ## M1: the owner execution boundary (marked kernel AND ordinary runtime)

  describe "in prototype runtime the marked kernel request is Forbidden, writing nothing" do
    test "Relocation :create", ctx do
      enter!(ctx.fx)
      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      before = {count(@relocation), head(ctx.fx), type_count(ctx.fx, @created)}

      result = create(ctx, 1, ctx.original, ctx.destination, owner(ctx.fx))

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "marked kernel create in prototype runtime: expected Forbidden, got #{inspect(result)}"

      assert {count(@relocation), head(ctx.fx), type_count(ctx.fx, @created)} == before
    end

    test "RelocationEvent :append", ctx do
      relocation = relocation!(ctx)
      enter!(ctx.fx)
      at_identity!(relocation, :planned)
      before = {count(@event), head(ctx.fx), type_count(ctx.fx, @appended)}

      result = append(relocation, :planned, owner(ctx.fx))

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "marked kernel append in prototype runtime: expected Forbidden, got #{inspect(result)}"

      assert {count(@event), head(ctx.fx), type_count(ctx.fx, @appended)} == before
    end

    test "an unmarked kernel request stays Forbidden in prototype runtime", ctx do
      relocation = relocation!(ctx)
      enter!(ctx.fx)

      unmarked = [
        actor: Actor.system(:kernel, ctx.fx.tenant.id),
        context: KernelContext.context()
      ]

      at_identity!(relocation, :planned)
      before = {count(@relocation), count(@event)}

      assert match?(
               {:error, %Ash.Error.Forbidden{}},
               create(ctx, 2, ctx.original, ctx.destination, unmarked)
             )

      assert match?({:error, %Ash.Error.Forbidden{}}, append(relocation, :planned, unmarked))
      assert {count(@relocation), count(@event)} == before
    end
  end

  describe "in ordinary runtime the marked kernel request is allowed" do
    test "create and append", ctx do
      relocation = relocation!(ctx)
      event = append!(ctx, relocation, :planned)
      assert event.kind == :planned
    end
  end
end

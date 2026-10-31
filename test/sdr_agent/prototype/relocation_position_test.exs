defmodule SdrAgent.Prototype.RelocationPositionTest do
  @moduledoc """
  S-B1 RED r5 M3 (corrective r3b, entity PASS bbb5c558; Codex GREEN review
  85b05b45 M3): `RelocationEvent.position`, the serialized append ordinal,
  is the only read order.

  Contract specified here:

  - `position` is a required positive integer, caller-unwritable (not an
    accepted input of `:append`): a caller-supplied position is refused or
    ignored;
  - it is force-set under the head lock to the count of recorded events
    plus one: it starts at 1 and is gap-free over successful appends; a
    rolled-back append (an out-of-order refusal, an insert failure)
    consumes none;
  - UNIQUE `(relocation_id, position)`: a unique, non-partial index on
    exactly those columns, which refuses a synthetic duplicate written
    below the application with `unique_violation`;
  - read order is by position everywhere: `Relocation.chain/2` (its plain
    event maps carry `position`) and the `events` relationship. With the
    test Clock reversed (each later append records an EARLIER
    `recorded_at`), a timestamp-sorted read fails.

  The concurrent successful pair is
  `SdrAgent.Prototype.RelocationPositionRaceTest`. Owner writes in
  ordinary runtime. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Clock
  alias SdrAgent.Prototype.Checks.KernelMarker

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @destination_kinds [:restored, :activated, :destination_disabled]
  @source_side [:planned, :writers_stopped, :fenced]

  setup do
    fx = bound!(enter_runtime: false)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    on_exit(&Clock.unfreeze/0)
    %{fx: fx, original: original, destination: destination}
  end

  ## Helpers

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  defp relocation!(ctx) do
    loaded!(@relocation)
    assert PrototypeFixtures.put_live_identity(ctx.original) == :ok

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

  defp append(ctx, relocation, kind, input \\ %{}) do
    loaded!(@event)
    identity = if kind in @destination_kinds, do: ctx.destination, else: ctx.original
    assert PrototypeFixtures.put_live_identity(identity) == :ok

    @event
    |> Ash.Changeset.for_create(
      :append,
      Map.merge(%{relocation_id: relocation.id, kind: kind}, input),
      owner(ctx.fx)
    )
    |> Ash.create()
  rescue
    error -> {:raised, error}
  end

  defp append!(ctx, relocation, kind) do
    result = append(ctx, relocation, kind)
    assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    {:ok, event} = result
    event
  end

  # The position attribute, or a failure naming its absence.
  defp position_attribute! do
    loaded!(@event)
    attribute = Ash.Resource.Info.attribute(@event, :position)
    assert attribute, "RelocationEvent has no position attribute"
    attribute
  end

  defp position!(event) do
    _ = position_attribute!()
    Map.get(event, :position)
  end

  defp table, do: AshPostgres.DataLayer.Info.table(loaded!(@event))

  defp count do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table()}", [])
    n
  end

  # The stored (kind, position) pairs of a relocation, by position.
  defp stored_positions(relocation) do
    _ = position_attribute!()

    Repo.query!(
      "SELECT kind::text, position FROM #{table()} WHERE relocation_id = $1 ORDER BY position",
      [Ecto.UUID.dump!(relocation.id)]
    ).rows
    |> Enum.map(fn [kind, position] -> {String.to_existing_atom(kind), position} end)
  end

  ## Structure

  describe "the position attribute" do
    test "is a required positive integer and not an accepted input of :append" do
      attribute = position_attribute!()
      assert attribute.allow_nil? == false, "position allows nil"
      assert attribute.type == Ash.Type.Integer, "position type: #{inspect(attribute.type)}"
      assert (attribute.constraints[:min] || 0) >= 1, "position has no min: 1 constraint"

      action = Ash.Resource.Info.action(@event, :append)
      assert action, "RelocationEvent has no :append action"
      refute :position in action.accept, "position is an accepted input of :append"
    end

    test "a caller-supplied position is refused or ignored", ctx do
      _ = position_attribute!()
      relocation = relocation!(ctx)
      result = append(ctx, relocation, :planned, %{position: 99})

      case result do
        {:ok, event} ->
          assert event.position == 1, "the caller-supplied position was stored: #{inspect(event)}"

        {:error, %Ash.Error.Invalid{}} ->
          assert count() == 0, "the refused append wrote a row"

        other ->
          flunk("a caller-supplied position: #{inspect(other)}")
      end
    end
  end

  ## Assignment

  describe "position assignment" do
    test "starts at 1 and is gap-free over successful appends", ctx do
      relocation = relocation!(ctx)

      positions =
        for kind <- @source_side ++ [:restored, :activated],
            do: position!(append!(ctx, relocation, kind))

      assert positions == [1, 2, 3, 4, 5]

      assert stored_positions(relocation) == [
               planned: 1,
               writers_stopped: 2,
               fenced: 3,
               restored: 4,
               activated: 5
             ]
    end

    test "a refused out-of-order append consumes no position", ctx do
      relocation = relocation!(ctx)
      assert position!(append!(ctx, relocation, :planned)) == 1

      refused = append(ctx, relocation, :fenced)
      assert match?({:error, %Ash.Error.Invalid{}}, refused), "prerequisite: out-of-order refusal"

      assert position!(append!(ctx, relocation, :writers_stopped)) == 2
      assert stored_positions(relocation) == [planned: 1, writers_stopped: 2]
    end

    test "an insert failure rolls back and consumes no position", ctx do
      relocation = relocation!(ctx)
      assert position!(append!(ctx, relocation, :planned)) == 1

      Repo.query!(
        """
        CREATE FUNCTION pg_temp.sdr_test_event_insert_fault() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'injected insert failure'; END $$ LANGUAGE plpgsql
        """,
        []
      )

      Repo.query!(
        "CREATE TRIGGER sdr_test_event_insert_fault BEFORE INSERT ON \"#{table()}\" " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.sdr_test_event_insert_fault()",
        []
      )

      failed = append(ctx, relocation, :writers_stopped)
      refute match?({:ok, _}, failed), "prerequisite: the injected insert failure"
      Repo.query!("DROP TRIGGER sdr_test_event_insert_fault ON \"#{table()}\"", [])

      assert position!(append!(ctx, relocation, :writers_stopped)) == 2
      assert stored_positions(relocation) == [planned: 1, writers_stopped: 2]
    end
  end

  ## Database uniqueness

  describe "UNIQUE (relocation_id, position) in the database" do
    defp position_index! do
      sql =
        "SELECT c.relname, " <>
          "array_agg(a.attname::text ORDER BY array_position(i.indkey::int2[], a.attnum)), " <>
          "pg_get_expr(i.indpred, i.indrelid) " <>
          "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) " <>
          "WHERE i.indrelid = $1::text::regclass AND i.indisunique " <>
          "GROUP BY c.relname, i.indpred, i.indrelid"

      indexes = Repo.query!(sql, [table()]).rows

      found =
        for [name, columns, nil] <- indexes,
            Enum.sort(columns) == ["position", "relocation_id"],
            do: name

      assert match?([_one], found),
             "expected one unique non-partial index on (relocation_id, position): " <>
               inspect(indexes)

      hd(found)
    end

    test "a unique index on exactly (relocation_id, position) exists" do
      _name = position_index!()
    end

    test "a synthetic duplicate position conflicts on that index", ctx do
      name = position_index!()
      relocation = relocation!(ctx)
      _planned = append!(ctx, relocation, :planned)
      t = table()

      # A copy of the planned row under a new id, below the application with
      # triggers off: only the index can refuse it.
      sql =
        "INSERT INTO \"#{t}\" SELECT (jsonb_populate_record(NULL::\"#{t}\", " <>
          "to_jsonb(e) || jsonb_build_object('id', gen_random_uuid()))).* " <>
          "FROM \"#{t}\" e WHERE e.relocation_id = $1 AND e.kind::text = 'planned'"

      result =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL session_replication_role = replica", [])

          case Repo.query(sql, [Ecto.UUID.dump!(relocation.id)]) do
            {:ok, inserted} -> Repo.rollback({:unexpected_success, inserted})
            {:error, error} -> Repo.rollback(error)
          end
        end)

      assert match?(
               {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: ^name}}},
               result
             ),
             "the duplicate position: #{inspect(result)}"

      assert count() == 1
    end
  end

  ## Read order

  describe "read order is by position, never recorded_at" do
    # Each later append records an EARLIER recorded_at.
    defp reversed_chain!(ctx) do
      relocation = relocation!(ctx)
      base = DateTime.add(Clock.utc_now(), 3_600, :second)

      for {kind, step} <- Enum.with_index(@source_side) do
        assert Clock.freeze(DateTime.add(base, -60 * step, :second)) == :ok
        append!(ctx, relocation, kind)
      end

      Clock.unfreeze()
      relocation
    end

    test "the reversed clock is in effect (prerequisite)", ctx do
      relocation = reversed_chain!(ctx)
      table = table()

      %{rows: rows} =
        Repo.query!(
          "SELECT kind::text FROM #{table} WHERE relocation_id = $1 ORDER BY recorded_at",
          [Ecto.UUID.dump!(relocation.id)]
        )

      assert List.flatten(rows) == ["fenced", "writers_stopped", "planned"]
    end

    test "Relocation.chain/2 lists events by position and carries it", ctx do
      _relocation = reversed_chain!(ctx)
      result = call(@relocation, :chain, [ctx.fx.binding.id, ctx.fx.tenant.id])
      assert match?({:ok, [_]}, result), "Relocation.chain/2: #{inspect(result)}"
      {:ok, [relocation]} = result

      assert Enum.map(relocation.events, & &1.kind) == @source_side,
             "chain read order: #{inspect(Enum.map(relocation.events, & &1.kind))}"

      assert Enum.map(relocation.events, &Map.get(&1, :position)) == [1, 2, 3],
             "chain event maps do not carry position: #{inspect(relocation.events)}"
    end

    test "the events relationship is sorted by position", ctx do
      relocation = reversed_chain!(ctx)
      # A test-only read of the relationship (its order, not its policy).
      loaded = Ash.load!(relocation, :events, authorize?: false)

      assert Enum.map(loaded.events, & &1.kind) == @source_side,
             "relationship order: #{inspect(Enum.map(loaded.events, & &1.kind))}"
    end
  end
end

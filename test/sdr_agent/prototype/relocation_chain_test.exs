defmodule SdrAgent.Prototype.RelocationChainTest do
  @moduledoc """
  S-B1 RED (ADR-0024 decision 1; plan R2 "Entities", r1 "TDD slices" 1): the
  append-only `SdrAgent.Prototype.Relocation` and
  `SdrAgent.Prototype.RelocationEvent` resources.

  Contract specified here:

  - `Relocation :create` accepts `binding_id`, `relocation_seq`,
    `from_identity` and `to_identity` (each an identity
    `%{database:, database_oid:, system_identifier:}`, read back with those
    atom keys); `(binding_id, relocation_seq)` is unique and the seq is the
    chain's next one (1 first, then the highest plus one); `from_identity`
    equals the chain's current authority under the head lock (the original
    with no activation, else the latest activated destination); any other
    from_identity (stale or third) is `Ash.Error.Invalid` with no row;
  - `RelocationEvent :append` accepts `relocation_id` and `kind`, one of
    planned, writers_stopped, fenced, restored, activated,
    destination_disabled, aborted; it records `identity` as the live
    database identity at the write (never caller-supplied), and
    `recorded_at`;
  - order: planned → writers_stopped → fenced → restored → activated; one
    event of each kind per relocation; planned is always first (so
    `aborted` on an empty event chain is refused); `aborted` only before `activated`
    and, when `restored` exists, only after `destination_disabled`;
    `destination_disabled` only after `restored` and before `activated`;
    nothing after `aborted` or `activated`; `activated` never after
    `destination_disabled`. An out-of-order append is `Ash.Error.Invalid`
    and writes no row;
  - both tables refuse UPDATE, DELETE and TRUNCATE (append-only triggers);
  - writes are owner-run only: a kernel request carrying the new
    `SdrAgent.Prototype.Checks.KernelMarker` `:relocation` marker; every
    other caller (unmarked kernel, `:setup` or `:task_entry` marker, no
    context, an admin or the operator carrying the marker) is
    `Ash.Error.Forbidden` and writes nothing.

  Owner-run writes are made in ordinary runtime (the release-eval steps do
  not boot the spending paths, plan r2 P3). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Prototype.Checks.KernelMarker

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @kinds [
    :planned,
    :writers_stopped,
    :fenced,
    :restored,
    :activated,
    :destination_disabled,
    :aborted
  ]
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

  defp action!(resource, name) do
    loaded!(resource)
    action = Ash.Resource.Info.action(resource, name)
    assert action, "#{inspect(resource)} has no #{name} action"
    assert action.type == :create, "#{inspect(resource)} #{name} is not a create action"
  end

  defp create_relocation(fx, seq, from, to, opts) do
    action!(@relocation, :create)

    @relocation
    |> Ash.Changeset.for_create(
      :create,
      %{binding_id: fx.binding.id, relocation_seq: seq, from_identity: from, to_identity: to},
      opts
    )
    |> Ash.create()
  end

  defp append(relocation, kind, opts) do
    action!(@event, :append)

    @event
    |> Ash.Changeset.for_create(:append, %{relocation_id: relocation.id, kind: kind}, opts)
    |> Ash.create()
  end

  defp relocation!(ctx, seq \\ 1) do
    result = create_relocation(ctx.fx, seq, ctx.original, ctx.destination, owner(ctx.fx))
    assert match?({:ok, %{id: _}}, result), "owner-run relocation create: #{inspect(result)}"
    {:ok, relocation} = result
    relocation
  end

  # Each event is written in the database it belongs to: source events at
  # the relocation's from_identity, destination events at its to_identity
  # (Codex pre-read 230844Z).
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
    assert match?({:ok, %{id: _}}, result), "owner-run append #{kind}: #{inspect(result)}"
    {:ok, event} = result
    event
  end

  defp chain!(ctx, relocation, kinds), do: Enum.each(kinds, &append!(ctx, relocation, &1))

  defp table(resource) do
    loaded!(resource)
    AshPostgres.DataLayer.Info.table(resource)
  end

  defp count(resource) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table(resource)}", [])
    n
  end

  defp ident(x),
    do: %{
      database: Map.get(x, :database),
      database_oid: Map.get(x, :database_oid),
      system_identifier: Map.get(x, :system_identifier)
    }

  defp refused_invalid!(ctx, relocation, kind) do
    at_identity!(relocation, kind)
    before = count(@event)
    result = append(relocation, kind, owner(ctx.fx))

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "#{kind} out of order: expected Invalid, got #{inspect(result)}"

    assert count(@event) == before, "#{kind} out of order wrote a row"
  end

  ## Structure

  describe "structure" do
    test "the two resources expose the R2 attributes" do
      for {resource, attrs} <- [
            {@relocation, [:binding_id, :relocation_seq, :from_identity, :to_identity]},
            {@event, [:relocation_id, :kind, :identity, :recorded_at, :recorded_by]}
          ] do
        loaded!(resource)

        for attr <- attrs do
          assert Ash.Resource.Info.attribute(resource, attr),
                 "#{inspect(resource)} has no #{attr} attribute"
        end
      end
    end

    test "(binding_id, relocation_seq) is an identity" do
      loaded!(@relocation)
      keys = Enum.map(Ash.Resource.Info.identities(@relocation), &Enum.sort(&1.keys))
      assert Enum.sort([:binding_id, :relocation_seq]) in keys, "identities: #{inspect(keys)}"
    end

    test "kind is constrained to exactly the seven event kinds" do
      loaded!(@event)
      attribute = Ash.Resource.Info.attribute(@event, :kind)
      assert attribute, "RelocationEvent has no kind attribute"
      assert Enum.sort(attribute.constraints[:one_of] || []) == Enum.sort(@kinds)
    end
  end

  ## Owner-run writes

  describe "the owner-run create and append" do
    test "the marked kernel request creates a relocation with both identities", ctx do
      relocation = relocation!(ctx)
      assert relocation.binding_id == ctx.fx.binding.id
      assert relocation.relocation_seq == 1
      assert ident(relocation.from_identity) == ctx.original
      assert ident(relocation.to_identity) == ctx.destination
    end

    test "an appended event records the live identity at the write", ctx do
      relocation = relocation!(ctx)
      planned = append!(ctx, relocation, :planned)
      assert planned.kind == :planned
      assert ident(planned.identity) == ctx.original
      assert match?(%DateTime{}, planned.recorded_at), "recorded_at: #{inspect(planned)}"

      chain!(ctx, relocation, [:writers_stopped, :fenced])
      assert PrototypeFixtures.put_live_identity(ctx.destination) == :ok
      restored = append!(ctx, relocation, :restored)
      assert ident(restored.identity) == ctx.destination
    end

    test "the full main branch appends in order", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored, :activated])
      assert count(@event) == 5
    end
  end

  describe "callers other than the marked kernel are Forbidden, writing nothing" do
    defp refused_callers(fx) do
      marker = relocation_context()
      kernel = Actor.system(:kernel, fx.tenant.id)

      [
        unmarked_kernel: [actor: kernel, context: KernelContext.context()],
        setup_marker: [actor: kernel, context: KernelMarker.context(:setup)],
        task_entry_marker: [actor: kernel, context: KernelMarker.context(:task_entry)],
        kernel_without_context: [actor: kernel],
        admin_with_marker: [actor: human(:admin, fx.tenant), context: marker],
        operator_with_marker: [actor: fx.actor, context: marker]
      ]
    end

    test "Relocation :create", ctx do
      callers = refused_callers(ctx.fx)
      before = count(@relocation)

      for {caller, opts} <- callers do
        result = create_relocation(ctx.fx, 1, ctx.original, ctx.destination, opts)

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{caller}: expected Forbidden, got #{inspect(result)}"
      end

      assert count(@relocation) == before
    end

    test "RelocationEvent :append", ctx do
      relocation = relocation!(ctx)
      callers = refused_callers(ctx.fx)
      before = count(@event)

      for {caller, opts} <- callers do
        result = append(relocation, :planned, opts)

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{caller}: expected Forbidden, got #{inspect(result)}"
      end

      assert count(@event) == before
    end
  end

  ## Sequence

  describe "relocation_seq" do
    test "the first relocation must be seq 1", ctx do
      result = create_relocation(ctx.fx, 2, ctx.original, ctx.destination, owner(ctx.fx))
      assert match?({:error, %Ash.Error.Invalid{}}, result), "seq 2 first: #{inspect(result)}"
    end

    test "a duplicated seq is refused", ctx do
      _first = relocation!(ctx, 1)
      result = create_relocation(ctx.fx, 1, ctx.original, ctx.destination, owner(ctx.fx))
      assert match?({:error, %Ash.Error.Invalid{}}, result), "duplicate seq: #{inspect(result)}"
      assert count(@relocation) == 1
    end

    test "a return relocation is seq + 1; a gap is refused", ctx do
      first = relocation!(ctx, 1)
      chain!(ctx, first, [:planned, :writers_stopped, :fenced, :restored, :activated])

      gap = create_relocation(ctx.fx, 3, ctx.destination, ctx.original, owner(ctx.fx))
      assert match?({:error, %Ash.Error.Invalid{}}, gap), "seq gap: #{inspect(gap)}"

      back = create_relocation(ctx.fx, 2, ctx.destination, ctx.original, owner(ctx.fx))
      assert match?({:ok, %{relocation_seq: 2}}, back), "return relocation: #{inspect(back)}"
    end
  end

  ## from_identity (Codex hold review 004447Z Pick3)

  describe "from_identity is the current authority under the head lock" do
    defp refused_create!(ctx, seq, from, to) do
      before = count(@relocation)
      result = create_relocation(ctx.fx, seq, from, to, owner(ctx.fx))

      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "from_identity #{inspect(from)}: expected Invalid, got #{inspect(result)}"

      assert count(@relocation) == before, "the refused create wrote a row"
    end

    test "with no activation, the original source identity succeeds", ctx do
      relocation = relocation!(ctx)
      assert ident(relocation.from_identity) == ctx.original
      assert count(@relocation) == 1
    end

    test "with no activation, the destination or a third identity is refused", ctx do
      stranger = %{ctx.original | database_oid: ctx.original.database_oid + 2_000}
      refused_create!(ctx, 1, ctx.destination, ctx.original)
      refused_create!(ctx, 1, stranger, ctx.destination)
    end

    test "after an activation, the stale source or a third identity is refused", ctx do
      first = relocation!(ctx, 1)
      chain!(ctx, first, [:planned, :writers_stopped, :fenced, :restored, :activated])
      stranger = %{ctx.original | database_oid: ctx.original.database_oid + 2_000}
      refused_create!(ctx, 2, ctx.original, ctx.destination)
      refused_create!(ctx, 2, stranger, ctx.original)
    end

    test "after an activation, seq + 1 from the activated destination succeeds", ctx do
      first = relocation!(ctx, 1)
      chain!(ctx, first, [:planned, :writers_stopped, :fenced, :restored, :activated])
      result = create_relocation(ctx.fx, 2, ctx.destination, ctx.original, owner(ctx.fx))
      assert match?({:ok, %{relocation_seq: 2}}, result), "return relocation: #{inspect(result)}"
      {:ok, back} = result

      assert {ident(back.from_identity), ident(back.to_identity)} ==
               {ctx.destination, ctx.original}

      assert count(@relocation) == 2
    end
  end

  ## Event identity

  describe "each event is refused at the wrong database identity" do
    defp refused_at!(ctx, relocation, kind, identity) do
      assert PrototypeFixtures.put_live_identity(identity) == :ok
      before = count(@event)
      result = append(relocation, kind, owner(ctx.fx))

      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "#{kind} at the wrong identity: expected Invalid, got #{inspect(result)}"

      assert count(@event) == before, "#{kind} at the wrong identity wrote a row"
    end

    test "source events are refused at the destination identity", ctx do
      relocation = relocation!(ctx)
      refused_at!(ctx, relocation, :planned, ctx.destination)
      append!(ctx, relocation, :planned)
      refused_at!(ctx, relocation, :writers_stopped, ctx.destination)
      append!(ctx, relocation, :writers_stopped)
      refused_at!(ctx, relocation, :fenced, ctx.destination)
      refused_at!(ctx, relocation, :aborted, ctx.destination)
    end

    test "restored and activated are refused at the source identity", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced])
      refused_at!(ctx, relocation, :restored, ctx.original)
      append!(ctx, relocation, :restored)
      refused_at!(ctx, relocation, :activated, ctx.original)
    end

    test "destination_disabled is refused at the source identity", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored])
      refused_at!(ctx, relocation, :destination_disabled, ctx.original)
    end

    test "a third identity is refused for every kind", ctx do
      relocation = relocation!(ctx)
      stranger = %{ctx.original | database_oid: ctx.original.database_oid + 2_000}

      for kind <- @kinds do
        refused_at!(ctx, relocation, kind, stranger)
      end
    end
  end

  ## Event order

  describe "main-branch order" do
    test "the first event must be planned", ctx do
      relocation = relocation!(ctx)

      for kind <- @kinds -- [:planned, :aborted] do
        refused_invalid!(ctx, relocation, kind)
      end
    end

    test "each main-branch step requires its predecessor", ctx do
      relocation = relocation!(ctx)
      append!(ctx, relocation, :planned)
      refused_invalid!(ctx, relocation, :fenced)
      refused_invalid!(ctx, relocation, :restored)
      refused_invalid!(ctx, relocation, :activated)

      append!(ctx, relocation, :writers_stopped)
      refused_invalid!(ctx, relocation, :restored)
      refused_invalid!(ctx, relocation, :activated)

      append!(ctx, relocation, :fenced)
      refused_invalid!(ctx, relocation, :activated)
      refused_invalid!(ctx, relocation, :destination_disabled)
    end

    test "no kind is appended twice", ctx do
      relocation = relocation!(ctx)
      append!(ctx, relocation, :planned)
      refused_invalid!(ctx, relocation, :planned)
      append!(ctx, relocation, :writers_stopped)
      refused_invalid!(ctx, relocation, :writers_stopped)
      append!(ctx, relocation, :fenced)
      refused_invalid!(ctx, relocation, :fenced)
    end

    test "at most one activated per relocation, and nothing after it", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored, :activated])

      for kind <- [:activated, :destination_disabled, :aborted] do
        refused_invalid!(ctx, relocation, kind)
      end
    end
  end

  describe "the abort branch" do
    # Codex hold review 004447Z Pick2: planned-first is the lifecycle, so
    # `aborted` on an empty event chain is refused.
    test "aborted on an empty event chain is refused, writing no row", ctx do
      relocation = relocation!(ctx)
      refused_invalid!(ctx, relocation, :aborted)
      assert count(@event) == 0
    end

    test "abort is allowed straight after planned", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :aborted])
    end

    # r3b M2 (Codex bbb5c558): interim post-fence abort refusal; fork-safe abort is S-B1b.
    test "abort after the fence, with nothing restored, is refused, writing no row", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced])
      refused_invalid!(ctx, relocation, :aborted)
    end

    # r3b M2 (Codex bbb5c558): interim post-fence abort refusal; fork-safe abort is S-B1b.
    test "after restored, abort is refused before and after destination_disabled", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored])
      refused_invalid!(ctx, relocation, :aborted)
      chain!(ctx, relocation, [:destination_disabled])
      refused_invalid!(ctx, relocation, :aborted)
    end

    test "destination_disabled requires restored", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped])
      refused_invalid!(ctx, relocation, :destination_disabled)
    end

    test "destination_disabled refuses a later activation", ctx do
      relocation = relocation!(ctx)

      chain!(ctx, relocation, [
        :planned,
        :writers_stopped,
        :fenced,
        :restored,
        :destination_disabled
      ])

      refused_invalid!(ctx, relocation, :activated)
    end

    test "nothing is appended after aborted", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :aborted])

      for kind <- @kinds do
        refused_invalid!(ctx, relocation, kind)
      end
    end
  end

  ## Append-only

  describe "append-only" do
    test "UPDATE, DELETE and TRUNCATE are rejected on both tables", ctx do
      relocation = relocation!(ctx)
      append!(ctx, relocation, :planned)

      for {resource, column} <- [{@relocation, "relocation_seq"}, {@event, "recorded_at"}] do
        t = table(resource)

        for sql <- [
              "UPDATE #{t} SET #{column} = #{column}",
              "DELETE FROM #{t}",
              "TRUNCATE #{t} CASCADE"
            ] do
          result = raw_error(sql)

          assert match?({:error, %Postgrex.Error{postgres: %{message: _}}}, result),
                 "#{sql}: #{inspect(result)}"

          {:error, %Postgrex.Error{postgres: %{message: message}}} = result
          assert message =~ "append-only", "#{sql}: #{message}"
        end
      end
    end
  end

  ## Database uniqueness of activated (Codex 230957Z must_fix 3)

  describe "at most one activated per relocation, in the database" do
    # The unique single-column indexes on relocation_id of the events
    # table: `{name, predicate}` (predicate nil when not partial).
    defp relocation_unique_indexes do
      sql =
        "SELECT c.relname, pg_get_expr(i.indpred, i.indrelid) " <>
          "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0] " <>
          "WHERE i.indrelid = $1::text::regclass AND i.indisunique AND i.indnatts = 1 " <>
          "AND a.attname = 'relocation_id'"

      Enum.map(Repo.query!(sql, [table(@event)]).rows, &List.to_tuple/1)
    end

    defp activated_only?(nil), do: false

    defp activated_only?(predicate),
      do: predicate =~ ~r/^\(\(?kind\)?(::[a-z ]+)? = 'activated'::[a-z ]+\)$/

    defp activated_index! do
      indexes = relocation_unique_indexes()
      found = for {name, predicate} <- indexes, activated_only?(predicate), do: name

      assert match?([_one], found),
             "expected one unique index on relocation_id WHERE kind = 'activated': " <>
               inspect(indexes)

      hd(found)
    end

    test "a unique index on relocation_id WHERE kind = 'activated' exists" do
      _name = activated_index!()
    end

    test "a synthetic second activated row conflicts on that index", ctx do
      name = activated_index!()
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored, :activated])
      t = table(@event)

      # A copy of the activated row under a new id, written below the
      # application with triggers off (the index is not a trigger): only the
      # index can refuse it.
      sql =
        "INSERT INTO \"#{t}\" SELECT (jsonb_populate_record(NULL::\"#{t}\", " <>
          "to_jsonb(e) || jsonb_build_object('id', gen_random_uuid()))).* " <>
          "FROM \"#{t}\" e WHERE e.relocation_id = $1 AND e.kind::text = 'activated'"

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
             "the duplicate activated: #{inspect(result)}"

      assert count(@event) == 5
    end
  end
end

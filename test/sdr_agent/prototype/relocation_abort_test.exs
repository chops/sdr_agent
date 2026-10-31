defmodule SdrAgent.Prototype.RelocationAbortTest do
  @moduledoc """
  S-B1 RED r5 M2 (corrective r3b, entity PASS bbb5c558; Codex GREEN review
  85b05b45 M2): the interim post-fence abort refusal. A source's local
  history cannot prove that no restored or activated copy exists, so
  `aborted` is allowed only while `planned` is recorded and `fenced` is
  not. The fork-safe post-fence abort (S-B1b) is INCOMPLETE; until it lands
  a source fenced by a failed move stays fenced.

  Contract specified here:

  - `aborted` succeeds after `planned` and after `writers_stopped`;
  - once `fenced` is recorded, `aborted` is `Ash.Error.Invalid` and writes
    no row and no `prototype.relocation.event_appended` event, in every
    path: with `restored` absent locally; with an independent destination
    history held in a second in-test chain value; and through the
    two-identity override (`restored` and `destination_disabled` written at
    the destination identity, the abort at the source);
  - pure witness on Codex's counterexample
    (`SdrAgent.Prototype.Changes.RelocationAppend.allowed?/2`,
    `SdrAgent.Prototype.CurrentAuthority`): source chain planned,
    writers_stopped, fenced; destination copy the same plus restored and
    activated. The source abort is not allowed, so at most one copy is
    spendable and unfenced.

  This is a state-machine and single-database witness, not a two-database
  run. Owner writes in ordinary runtime. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype.Checks.KernelMarker

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @append_rules SdrAgent.Prototype.Changes.RelocationAppend
  @authority SdrAgent.Prototype.CurrentAuthority
  @appended "prototype.relocation.event_appended"
  @destination_kinds [:restored, :activated, :destination_disabled]

  @db "sdr_agent_prototype"
  @a %{database: @db, database_oid: 16_384, system_identifier: 7_100_000_000_000_000_001}
  @b %{database: @db, database_oid: 24_576, system_identifier: 7_200_000_000_000_000_002}

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

  defp at_identity!(ctx, kind) do
    identity = if kind in @destination_kinds, do: ctx.destination, else: ctx.original
    assert PrototypeFixtures.put_live_identity(identity) == :ok
  end

  defp chain!(ctx, relocation, kinds) do
    for kind <- kinds do
      at_identity!(ctx, kind)
      result = append(ctx, relocation, kind)
      assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    end

    :ok
  end

  defp event_rows do
    loaded!(@event)
    table = AshPostgres.DataLayer.Info.table(@event)
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  defp ledger(ctx, relocation) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND payload -> 'changes' ->> 'relocation_id' = $3",
        [Ecto.UUID.dump!(ctx.fx.tenant.id), @appended, relocation.id]
      )

    n
  end

  defp aborted_rows(relocation) do
    table = AshPostgres.DataLayer.Info.table(@event)

    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM #{table} WHERE relocation_id = $1 AND kind::text = 'aborted'",
        [Ecto.UUID.dump!(relocation.id)]
      )

    n
  end

  defp refused_abort!(ctx, relocation, label) do
    at_identity!(ctx, :aborted)
    before = {event_rows(), ledger(ctx, relocation)}
    result = append(ctx, relocation, :aborted)

    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "post-fence abort (#{label}): expected Invalid, got #{inspect(result)}"

    assert {event_rows(), ledger(ctx, relocation)} == before,
           "the refused post-fence abort (#{label}) wrote a row or ledger event"

    assert aborted_rows(relocation) == 0
  end

  defp chain_value!(ctx) do
    result = call(@relocation, :chain, [ctx.fx.binding.id, ctx.fx.tenant.id])
    assert match?({:ok, [_]}, result), "prerequisite: Relocation.chain/2: #{inspect(result)}"
    {:ok, chain} = result
    chain
  end

  ## Before the fence

  describe "aborted before the fence" do
    test "succeeds after planned", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :aborted])
      assert aborted_rows(relocation) == 1
    end

    test "succeeds after writers_stopped", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :aborted])
      assert aborted_rows(relocation) == 1
    end
  end

  ## Once fenced is recorded

  describe "aborted is refused once fenced is recorded" do
    test "with restored absent locally", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced])
      refused_abort!(ctx, relocation, "restored absent")
    end

    test "with an independent destination history in a second chain value", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced])

      # The source database's own chain, and the destination copy's
      # independent history: the same prefix, then restored and activated
      # at the destination identity (never written to the source database).
      [source] = source_chain = chain_value!(ctx)
      prefix = source.events
      n = length(prefix)

      destination_chain = [
        %{
          source
          | events:
              prefix ++
                [
                  %{kind: :restored, identity: ctx.destination, position: n + 1},
                  %{kind: :activated, identity: ctx.destination, position: n + 2}
                ]
        }
      ]

      refused_abort!(ctx, relocation, "independent destination history")

      assert chain_value!(ctx) == source_chain, "the source chain changed"
      assert call(@authority, :fenced?, [source_chain, ctx.original])
      assert call(@authority, :spendable?, [destination_chain, ctx.original, ctx.destination])
      refute call(@authority, :fenced?, [destination_chain, ctx.destination])

      usable =
        Enum.count(
          [{source_chain, ctx.original}, {destination_chain, ctx.destination}],
          fn {chain, live} ->
            call(@authority, :spendable?, [chain, ctx.original, live]) and
              not call(@authority, :fenced?, [chain, live])
          end
        )

      assert usable == 1, "#{usable} copies are spendable and unfenced"
    end

    test "through the two-identity override", ctx do
      relocation = relocation!(ctx)
      chain!(ctx, relocation, [:planned, :writers_stopped, :fenced, :restored])
      refused_abort!(ctx, relocation, "after restored")
      chain!(ctx, relocation, [:destination_disabled])
      refused_abort!(ctx, relocation, "after destination_disabled")
    end
  end

  ## Pure witness (Codex 85b05b45 M2 counterexample)

  describe "pure witness: the source abort cannot make both copies spendable" do
    defp ev(kind, identity, position), do: %{kind: kind, identity: identity, position: position}

    defp relocation(events),
      do: %{relocation_seq: 1, from_identity: @a, to_identity: @b, events: events}

    test "source planned, writers_stopped, fenced; destination adds restored, activated" do
      prefix = [ev(:planned, @a, 1), ev(:writers_stopped, @a, 2), ev(:fenced, @a, 3)]
      source = [relocation(prefix)]
      destination = [relocation(prefix ++ [ev(:restored, @b, 4), ev(:activated, @b, 5)])]
      source_kinds = Enum.map(prefix, & &1.kind)

      refute call(@append_rules, :allowed?, [:aborted, source_kinds]),
             "the source may abort after its fence"

      # Whatever the rule allows is applied to the source.
      source =
        if call(@append_rules, :allowed?, [:aborted, source_kinds]),
          do: [relocation(prefix ++ [ev(:aborted, @a, 4)])],
          else: source

      usable =
        for {chain, live} <- [{source, @a}, {destination, @b}] do
          call(@authority, :spendable?, [chain, @a, live]) and
            not call(@authority, :fenced?, [chain, live])
        end

      assert usable == [false, true],
             "spendable-and-unfenced {source, destination}: #{inspect(usable)}"
    end

    test "aborted stays allowed after planned and after writers_stopped" do
      assert call(@append_rules, :allowed?, [:aborted, [:planned]])
      assert call(@append_rules, :allowed?, [:aborted, [:planned, :writers_stopped]])
      refute call(@append_rules, :allowed?, [:aborted, []])
    end

    test "aborted is refused once fenced is recorded, whatever follows" do
      for recorded <- [
            [:planned, :writers_stopped, :fenced],
            [:planned, :writers_stopped, :fenced, :restored],
            [:planned, :writers_stopped, :fenced, :restored, :destination_disabled]
          ] do
        refute call(@append_rules, :allowed?, [:aborted, recorded]),
               "aborted allowed after #{inspect(recorded)}"
      end
    end
  end
end

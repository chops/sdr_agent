defmodule SdrAgent.Prototype.RelocationCurrentAuthorityTest do
  @moduledoc """
  S-B1 RED (ADR-0024 decision 1; plan R2 "Predicates", r4a C1): the pure
  `SdrAgent.Prototype.CurrentAuthority` predicates over a relocation chain,
  the binding's original identity and a live identity. No database.

  Contract specified here:

  - an identity is `%{database:, database_oid:, system_identifier:}`;
  - a chain is a list of relocations
    `%{relocation_seq:, from_identity:, to_identity:, events: [%{kind:, identity:}]}`,
    each relocation's events in recorded order;
  - `identity(chain, original)` is `{:ok, identity}`: the original with no
    activation, else the `to_identity` of the highest-seq relocation holding
    an `:activated` event; a chain with two `:activated` events in one
    relocation, or a duplicated `relocation_seq`, is `{:error, :chain_invalid}`;
  - `spendable?(chain, original, live)` is true exactly when the chain is
    valid and `live` equals the current authority (C1: any other live
    identity, including a superseded authority or a restored archive, is
    non-spendable);
  - `fenced?(chain, live)` is true when some relocation holds a `:fenced`
    event whose identity equals `live` with no later `:aborted` in the same
    relocation (the copied fence names the source, not the destination);
  - `next_seq(chain)` is the highest `relocation_seq` plus one (1 when empty):
    a return relocation is seq + 1.

  Synthetic identities only.
  """
  use ExUnit.Case, async: true

  @authority SdrAgent.Prototype.CurrentAuthority

  @db "sdr_agent_prototype"
  @a %{database: @db, database_oid: 16_384, system_identifier: 7_100_000_000_000_000_001}
  @b %{database: @db, database_oid: 24_576, system_identifier: 7_200_000_000_000_000_002}
  @c %{database: @db, database_oid: 32_768, system_identifier: 7_300_000_000_000_000_003}

  defp call(fun, args) do
    assert Code.ensure_loaded?(@authority), "#{inspect(@authority)} does not exist"
    arity = length(args)

    assert function_exported?(@authority, fun, arity),
           "#{inspect(@authority)}.#{fun}/#{arity} is not exported"

    Kernel.apply(Function.capture(@authority, fun, arity), args)
  end

  defp ev(kind, identity), do: %{kind: kind, identity: identity}

  defp relocation(seq, from, to, events),
    do: %{relocation_seq: seq, from_identity: from, to_identity: to, events: events}

  # The source-side prefix of a relocation from `from`.
  defp fenced_prefix(from),
    do: [ev(:planned, from), ev(:writers_stopped, from), ev(:fenced, from)]

  defp activated(seq, from, to) do
    relocation(seq, from, to, fenced_prefix(from) ++ [ev(:restored, to), ev(:activated, to)])
  end

  describe "current authority" do
    test "with no relocation it is the binding's original identity" do
      assert call(:identity, [[], @a]) == {:ok, @a}
    end

    test "with relocations but no activation it is still the original identity" do
      chain = [relocation(1, @a, @b, fenced_prefix(@a) ++ [ev(:restored, @b)])]
      assert call(:identity, [chain, @a]) == {:ok, @a}
    end

    test "an aborted relocation leaves the original identity" do
      chain = [
        relocation(
          1,
          @a,
          @b,
          fenced_prefix(@a) ++
            [ev(:restored, @b), ev(:destination_disabled, @b), ev(:aborted, @a)]
        )
      ]

      assert call(:identity, [chain, @a]) == {:ok, @a}
    end

    test "after one activation it is that relocation's to_identity" do
      assert call(:identity, [[activated(1, @a, @b)], @a]) == {:ok, @b}
    end

    test "the highest-seq activation wins, whatever the list order" do
      chain = [activated(2, @b, @c), activated(1, @a, @b)]
      assert call(:identity, [chain, @a]) == {:ok, @c}
    end

    test "a later relocation that is not activated does not move authority" do
      chain = [activated(1, @a, @b), relocation(2, @b, @a, fenced_prefix(@b))]
      assert call(:identity, [chain, @a]) == {:ok, @b}
    end

    test "two activated events in one relocation make the chain invalid" do
      twice = activated(1, @a, @b)
      chain = [%{twice | events: twice.events ++ [ev(:activated, @b)]}]
      assert call(:identity, [chain, @a]) == {:error, :chain_invalid}
    end

    test "a duplicated relocation_seq makes the chain invalid" do
      chain = [activated(1, @a, @b), activated(1, @a, @c)]
      assert call(:identity, [chain, @a]) == {:error, :chain_invalid}
    end
  end

  describe "return relocation (seq + 1)" do
    test "next_seq is 1 for an empty chain and the highest seq plus one otherwise" do
      assert call(:next_seq, [[]]) == 1
      assert call(:next_seq, [[activated(1, @a, @b)]]) == 2
      assert call(:next_seq, [[activated(2, @b, @a), activated(1, @a, @b)]]) == 3
    end

    test "a return relocation through seq + 1 restores the original as authority" do
      chain = [activated(1, @a, @b), activated(2, @b, @a)]
      assert call(:identity, [chain, @a]) == {:ok, @a}
      assert call(:spendable?, [chain, @a, @a])
      refute call(:spendable?, [chain, @a, @b]), "the superseded destination stayed spendable"
    end
  end

  describe "spendable? (C1 read-only recovery)" do
    test "with no relocation only the original identity is spendable" do
      assert call(:spendable?, [[], @a, @a])
      refute call(:spendable?, [[], @a, @b])
    end

    test "after activation the destination is spendable and the source is not" do
      chain = [activated(1, @a, @b)]
      assert call(:spendable?, [chain, @a, @b])
      refute call(:spendable?, [chain, @a, @a]), "the relocated-away source stayed spendable"
    end

    test "a restored archive, matching no activation and not the original, is non-spendable" do
      chain = [activated(1, @a, @b)]
      refute call(:spendable?, [chain, @a, @c])
      refute call(:spendable?, [[], @a, @c])
    end

    test "an invalid chain is spendable for no identity" do
      twice = activated(1, @a, @b)
      chain = [%{twice | events: twice.events ++ [ev(:activated, @b)]}]

      for live <- [@a, @b, @c] do
        refute call(:spendable?, [chain, @a, live]),
               "invalid chain spendable for #{inspect(live)}"
      end
    end
  end

  describe "fenced? (identity-scoped fence)" do
    test "no chain, or no fenced event, fences nothing" do
      refute call(:fenced?, [[], @a])
      refute call(:fenced?, [[relocation(1, @a, @b, [ev(:planned, @a)])], @a])
    end

    test "a fenced event naming the live identity fences it" do
      assert call(:fenced?, [[relocation(1, @a, @b, fenced_prefix(@a))], @a])
    end

    test "the copied fence naming the source does not fence the destination" do
      chain = [relocation(1, @a, @b, fenced_prefix(@a) ++ [ev(:restored, @b)])]
      refute call(:fenced?, [chain, @b])
      refute call(:fenced?, [[activated(1, @a, @b)], @b])
    end

    test "the source stays fenced after activation" do
      assert call(:fenced?, [[activated(1, @a, @b)], @a])
    end

    test "a later aborted in the same relocation lifts the fence" do
      chain = [relocation(1, @a, @b, fenced_prefix(@a) ++ [ev(:aborted, @a)])]
      refute call(:fenced?, [chain, @a])
    end

    test "an aborted in another relocation does not lift this relocation's fence" do
      chain = [
        relocation(1, @a, @b, [ev(:planned, @a), ev(:aborted, @a)]),
        relocation(2, @a, @b, fenced_prefix(@a))
      ]

      assert call(:fenced?, [chain, @a])
    end

    test "an aborted recorded before the fenced event does not lift it" do
      chain = [relocation(1, @a, @b, [ev(:planned, @a), ev(:aborted, @a), ev(:fenced, @a)])]
      assert call(:fenced?, [chain, @a])
    end
  end
end

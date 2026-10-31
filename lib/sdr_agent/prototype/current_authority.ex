defmodule SdrAgent.Prototype.CurrentAuthority do
  @moduledoc """
  The pure current-authority predicates over a relocation chain (ADR-0024
  decision 1; plan R2 "Predicates", r4a C1). No database, no process state.

  - An identity is `%{database:, database_oid:, system_identifier:}`; only
    those three keys are compared.
  - A chain is a list of relocations
    `%{relocation_seq:, from_identity:, to_identity:, events: [%{kind:, identity:, position:}]}`,
    in any order; each event carries its serialized `position`, and the
    events of a relocation are ordered by `position` only, never by list
    order, timestamp or id (`SdrAgent.Prototype.Relocation.chain/2` reads
    one from the database).
  - `identity/2`: `{:ok, identity}`, the binding's original identity when no
    relocation holds an `:activated` event, else the `to_identity` of the
    highest-seq relocation that does; `{:error, :chain_invalid}` when a
    `relocation_seq` repeats or one relocation holds two `:activated`
    events.
  - `spendable?/3`: true exactly when the chain is valid and the live
    identity equals the current authority. A superseded authority and a
    restored archive (matching no activation and not the original) are
    never spendable.
  - `fenced?/2`: true when some relocation holds a `:fenced` event whose
    identity equals the live identity with no `:aborted` event at a later
    `position` in that relocation. The copied fence names the source, so it never fences
    a destination with another identity.
  - `next_seq/1`: the highest `relocation_seq` plus one, 1 for an empty
    chain (a return relocation is seq + 1).
  """

  @keys [:database, :database_oid, :system_identifier]

  @type identity :: %{
          database: String.t(),
          database_oid: pos_integer(),
          system_identifier: integer()
        }
  @type event :: %{kind: atom(), identity: identity(), position: pos_integer()}
  @type relocation :: %{
          relocation_seq: pos_integer(),
          from_identity: identity(),
          to_identity: identity(),
          events: [event()]
        }
  @type chain :: [relocation()]

  @doc "The current-authority identity of `chain` over the binding's `original` identity."
  @spec identity(chain(), identity()) :: {:ok, identity()} | {:error, :chain_invalid}
  def identity(chain, original) do
    if valid?(chain) do
      chain
      |> Enum.filter(&activated?/1)
      |> Enum.max_by(& &1.relocation_seq, fn -> nil end)
      |> case do
        nil -> {:ok, normalize(original)}
        relocation -> {:ok, normalize(relocation.to_identity)}
      end
    else
      {:error, :chain_invalid}
    end
  end

  @doc "True exactly when `chain` is valid and `live` is its current authority."
  @spec spendable?(chain(), identity(), identity()) :: boolean()
  def spendable?(chain, original, live) do
    case identity(chain, original) do
      {:ok, current} -> current == normalize(live)
      {:error, :chain_invalid} -> false
    end
  end

  @doc "True when a fenced event of some relocation names `live` and no later aborted lifts it."
  @spec fenced?(chain(), identity()) :: boolean()
  def fenced?(chain, live) do
    live = normalize(live)
    Enum.any?(chain, &fences?(Enum.sort_by(&1.events, fn event -> event.position end), live))
  end

  @doc "The next relocation_seq: the highest plus one, 1 for an empty chain."
  @spec next_seq(chain()) :: pos_integer()
  def next_seq(chain) do
    chain
    |> Enum.map(& &1.relocation_seq)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  @doc "The three identity keys of `identity` (any other key dropped); nil for a non-map."
  @spec normalize(term()) :: identity() | nil
  def normalize(identity) when is_map(identity), do: Map.new(@keys, &{&1, Map.get(identity, &1)})
  def normalize(_other), do: nil

  defp valid?(chain) do
    seqs = Enum.map(chain, & &1.relocation_seq)

    length(Enum.uniq(seqs)) == length(seqs) and
      Enum.all?(chain, &(Enum.count(&1.events, fn event -> event.kind == :activated end) <= 1))
  end

  defp activated?(relocation), do: Enum.any?(relocation.events, &(&1.kind == :activated))

  # A fenced event naming `live`, with no aborted after it in this
  # relocation; `events` are sorted by position.
  defp fences?([], _live), do: false

  defp fences?([%{kind: :fenced, identity: identity} | rest], live) do
    (normalize(identity) == live and not Enum.any?(rest, &(&1.kind == :aborted))) or
      fences?(rest, live)
  end

  defp fences?([_event | rest], live), do: fences?(rest, live)
end

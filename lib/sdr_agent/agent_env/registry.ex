defmodule SdrAgent.AgentEnv.Registry do
  @moduledoc """
  The compiled authorization registry of the agent environment `agentenv-1`
  (ADR-0004 agent-environment amendment, items 4 and 8; C2* slice S2).

  An authorization is one reviewed code entry (`SdrAgent.AgentEnv.Registry.Entry`)
  that carries the owner's enforceable caps verbatim: an aggregate
  `total_attempts`, an optional `per_utc_day_attempts`, the `profile_ids`, the
  `funded_scope` and one allocation per approved window. The registry holds
  at most one entry for `agentenv-1`. An entry grants nothing by itself: it is
  materialized as at most one delegated grant by the provisioning action,
  and every spend is checked again at admission.

  **Shipped entries: none.** `entries/0` is `[]` until the owner's caps are
  recorded in a decision row and copied here by a reviewed change whose
  non-author reviewer verifies the copy. Until then nothing can be
  provisioned or spent.

  **Digest contract.** `sha256/1`, the authorization's SHA-256 that claim
  files, final binding files and delegated grants carry, is the lowercase hex
  SHA-256 of `SdrAgent.Audit.Canonical.encode!(Map.from_struct(entry))`
  (`sdr-canonical-json/1`). That is the entry's ten fields as one JSON object
  with string keys in byte order, with no `__struct__` key and no envelope:
  the funded-scope tuples become arrays, atoms their names, and timestamps
  UTC ISO-8601 with six fraction digits, whatever their precision. Every
  consumer binds these bytes.

  **Validation** (`validate/1`) checks the closed shape only. Expiry is not
  a shape rule: provisioning and admission check the actual time.

  **Test seam.** In test-seam builds only (`:claude_cli_test_seams`), the
  configuration `config :sdr_agent, SdrAgent.AgentEnv.Registry,
  test_entries: [...]` adds synthetic entries, read on every call. Other
  builds compile no such branch, and no runtime configuration adds an entry.
  """

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit.Canonical

  defmodule Entry do
    @moduledoc """
    One authorization of the agent environment (see
    `SdrAgent.AgentEnv.Registry`): its `id`, the `decision_refs` (the owner's
    caps decision row, `D-219` and `D-221`), `environment_id`, the
    `starts_at`/`expires_at` window, `funded_scope`, `total_attempts`, the
    optional `per_utc_day_attempts`, `profile_ids` and `allocations`. Each
    allocation is `%{key:, applies_to: [:b1], attempts:, available_from:,
    available_until:}`.
    """

    @enforce_keys [
      :id,
      :decision_refs,
      :environment_id,
      :starts_at,
      :expires_at,
      :funded_scope,
      :total_attempts,
      :profile_ids,
      :allocations
    ]
    defstruct @enforce_keys ++ [per_utc_day_attempts: nil]

    @type allocation :: %{
            key: atom(),
            applies_to: [:b1],
            attempts: pos_integer(),
            available_from: DateTime.t(),
            available_until: DateTime.t()
          }

    @type t :: %__MODULE__{
            id: String.t(),
            decision_refs: [String.t()],
            environment_id: String.t(),
            starts_at: DateTime.t(),
            expires_at: DateTime.t(),
            funded_scope: [{:assignment, [atom()]}],
            total_attempts: pos_integer(),
            per_utc_day_attempts: pos_integer() | nil,
            profile_ids: [atom()],
            allocations: [allocation()]
          }
  end

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @environment "agentenv-1"
  @funded_scope [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}]
  @fixed_refs ["D-219", "D-221"]
  @allocation_keys [:applies_to, :attempts, :available_from, :available_until, :key]

  # The reviewed entries: EMPTY until the owner's caps exist (ADR-0004 item 8).
  @entries []

  @doc "Every authorization entry: the shipped ones (none), plus test-seam entries in test builds."
  @spec entries() :: [Entry.t()]
  def entries, do: @entries ++ test_entries()

  if @test_seams do
    defp test_entries,
      do: :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:test_entries, [])
  else
    defp test_entries, do: []
  end

  @doc """
  The entry with `id`, or `:error`. The id is checked against the closed
  pattern (`^[a-z0-9][a-z0-9.-]{0,63}$`) before any lookup.
  """
  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(id) do
    with true <- id?(id),
         [%Entry{} = entry] <- Enum.filter(entries(), &match?(%Entry{id: ^id}, &1)) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  @doc "The one entry for `agentenv-1`, or `:none` when there is none or more than one."
  @spec current() :: {:ok, Entry.t()} | :none
  def current do
    case Enum.filter(entries(), &match?(%Entry{environment_id: @environment}, &1)) do
      [entry] -> {:ok, entry}
      _ -> :none
    end
  end

  @doc """
  The authorization's SHA-256: the lowercase hex SHA-256 of
  `Canonical.encode!(Map.from_struct(entry))` (the digest contract in the
  moduledoc).
  """
  @spec sha256(Entry.t()) :: String.t()
  def sha256(%Entry{} = entry) do
    entry |> Map.from_struct() |> Canonical.sha256() |> Base.encode16(case: :lower)
  end

  @doc "The only funded scope: assignment runs, for the three assignment purposes."
  @spec funded_scope() :: [{:assignment, [atom()]}]
  def funded_scope, do: @funded_scope

  @doc """
  `:ok` when `entry` has the closed shape, else `{:error, reason}` for the
  first rule it breaks: the id pattern; environment `agentenv-1`; exactly
  `funded_scope/0`; `total_attempts` ≥ 1; `per_utc_day_attempts` nil or ≥ 1;
  `profile_ids` a non-empty list of real profiles including
  `:claude_cli_opus`; `starts_at` before `expires_at`; `decision_refs` the
  caps row plus `D-219` and `D-221`; at least one allocation, each with
  exactly the closed keys, a distinct key from `ModelCallAllocation.keys/0`,
  `applies_to: [:b1]`, attempts ≥ 1 and both window bounds; pairwise
  disjoint half-open windows; attempts summing to at most the total; and at
  most one registry entry for the environment. Time is not consulted.
  """
  @spec validate(Entry.t()) :: :ok | {:error, atom()}
  def validate(%Entry{} = entry) do
    Enum.find_value(rules(), :ok, fn {reason, holds?} ->
      if holds?.(entry), do: nil, else: {:error, reason}
    end)
  end

  # In order: a later rule may rely on the earlier ones.
  defp rules do
    [
      invalid_id: &id?(&1.id),
      invalid_environment: &(&1.environment_id == @environment),
      invalid_funded_scope: &(&1.funded_scope == @funded_scope),
      invalid_total_attempts: &positive?(&1.total_attempts),
      invalid_per_utc_day_attempts:
        &(is_nil(&1.per_utc_day_attempts) or positive?(&1.per_utc_day_attempts)),
      invalid_profile_ids: &profiles?(&1.profile_ids),
      invalid_window: &before?(&1.starts_at, &1.expires_at),
      invalid_decision_refs: &refs?(&1.decision_refs),
      invalid_allocations: &allocations?(&1.allocations),
      overlapping_allocations: &disjoint?(&1.allocations),
      allocations_above_total: &(attempts(&1.allocations) <= &1.total_attempts),
      another_authorization: &sole?/1
    ]
  end

  defp id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, id)

  defp positive?(n), do: is_integer(n) and n >= 1

  defp profiles?(ids) do
    is_list(ids) and ids != [] and :claude_cli_opus in ids and
      Enum.all?(ids, &(&1 in ModelProfiles.real_ids()))
  end

  defp before?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :lt
  defp before?(_a, _b), do: false

  defp refs?(refs) when is_list(refs) and length(refs) == 3 do
    Enum.all?(refs, &decision_id?/1) and Enum.uniq(refs) == refs and
      Enum.all?(@fixed_refs, &(&1 in refs))
  end

  defp refs?(_refs), do: false

  defp decision_id?(ref), do: is_binary(ref) and Regex.match?(~r/\AD-[0-9]+\z/, ref)

  defp allocations?([_ | _] = allocations) do
    Enum.all?(allocations, &allocation?/1) and
      length(Enum.uniq_by(allocations, & &1.key)) == length(allocations)
  end

  defp allocations?(_allocations), do: false

  defp allocation?(allocation) when is_map(allocation) and not is_struct(allocation) do
    Enum.sort(Map.keys(allocation)) == @allocation_keys and
      allocation.key in ModelCallAllocation.keys() and allocation.applies_to == [:b1] and
      positive?(allocation.attempts) and match?(%DateTime{}, allocation.available_from) and
      match?(%DateTime{}, allocation.available_until)
  end

  defp allocation?(_allocation), do: false

  # Sorted by start, half-open windows are pairwise disjoint when each ends
  # no later than the next one starts.
  defp disjoint?(allocations) do
    allocations
    |> Enum.sort_by(& &1.available_from, DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> DateTime.compare(a.available_until, b.available_from) != :gt end)
  end

  defp attempts(allocations), do: allocations |> Enum.map(& &1.attempts) |> Enum.sum()

  defp sole?(%Entry{environment_id: environment}),
    do: Enum.count(entries(), &match?(%Entry{environment_id: ^environment}, &1)) <= 1
end

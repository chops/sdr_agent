# The D-237 repo_state adapter exists only in builds that compile the
# prototype authority (config/dev.exs and config/test.exs); the production
# build contains no adapter code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.RepoState do
    @moduledoc """
    The real `repo_state/0` effect of D-237 setup phase 1 (setup contract r6
    A1, Codex correlations m_1793194297723131417_77c441d5 and
    m_1793194953010412292_25f4fb18): whether the calling process may proceed
    to storage, decided before any storage effect.

    - `observe/0` takes a BOUNDED OBSERVATION of public, query-free state:
      the selected dynamic repo, the local name `SdrAgent.Repo` before and
      after, whether `:ecto` is started, and `Ecto.Repo.all_running/0` only
      when it is. It is several reads, not an atomic snapshot.
    - `decide/1` is pure and total: an exact five-key observation gives
      `:not_started` (the default name positively free, S1/S2),
      `:observe_transaction` (a stable, listed, default-named Repo, S3) or
      `:unavailable` (every unsupported or malformed state, U1-U7).
    - `transaction_result/1` is pure: `true` and `false` give
      `{:started, boolean}`, anything else `:unavailable`.
    - `repo_state/0` calls `SdrAgent.Repo.in_transaction?/0` ONLY after
      `decide/1` returned `:observe_transaction`.

    No SQL, no start, stop, registration or repair, no rescue and no
    private `Ecto.Repo.Registry` call; raises propagate. The result holds
    for one bounded observation only (contract r6 A1 limits); the
    in-callback transaction guard of `Setup` stays.

    `decide/1`, in order (the first failing check is `:unavailable`):
    exactly the five keys; `dynamic` is exactly `SdrAgent.Repo` (U1); both
    names are nil or a pid and equal (malformed, U6); then, with `:ecto`
    not started, `running` is exactly `:not_observed` and the name is free
    (S1; a held name is U3); with `:ecto` started, `running` is a proper
    list of non-nil atoms and pids with no pid (U2), and the number of
    `SdrAgent.Repo` entries decides: none with the name free (S2), exactly
    one with the name held (S3, `:observe_transaction`); any other count
    is U4, U5 or U7.

    Limits: the observation is bounded, not atomic or linearizable; stable
    names do not rule out ABA or a registry restart between the reads; a
    Repo started or stopped afterwards, concurrent starts and another
    process's transaction are outside it.
    """

    @keys [:dynamic, :ecto_started, :named_after, :named_before, :running]

    @type observation :: %{
            dynamic: term(),
            named_before: pid() | nil,
            ecto_started: boolean(),
            running: [atom() | pid()] | :not_observed,
            named_after: pid() | nil
          }
    @type decision :: :not_started | :observe_transaction | :unavailable
    @type state :: :not_started | {:started, boolean()} | :unavailable

    @doc """
    The bounded observation (contract r6 A1): public, query-free reads in
    this order, `Ecto.Repo.all_running/0` only when `:ecto` is started (a
    missing registry table then raises).
    """
    @spec observe() :: observation()
    def observe do
      dynamic = SdrAgent.Repo.get_dynamic_repo()
      named_before = Process.whereis(SdrAgent.Repo)
      ecto_started = List.keymember?(Application.started_applications(), :ecto, 0)
      running = if ecto_started, do: Ecto.Repo.all_running(), else: :not_observed
      named_after = Process.whereis(SdrAgent.Repo)

      %{
        dynamic: dynamic,
        named_before: named_before,
        ecto_started: ecto_started,
        running: running,
        named_after: named_after
      }
    end

    @doc "The pure decision over one observation; see the moduledoc."
    @spec decide(term()) :: decision()
    def decide(observation) when is_map(observation) and map_size(observation) == 5 do
      if Enum.sort(Map.keys(observation)) == @keys,
        do: decide_shaped(observation),
        else: :unavailable
    end

    def decide(_observation), do: :unavailable

    @doc "The pure validation of the transaction observation."
    @spec transaction_result(term()) :: {:started, boolean()} | :unavailable
    def transaction_result(true), do: {:started, true}
    def transaction_result(false), do: {:started, false}
    def transaction_result(_flag), do: :unavailable

    @doc """
    The real `repo_state/0` effect (contract r6 A1): `SdrAgent.Repo.in_transaction?/0`
    is called only after `decide/1` returned `:observe_transaction`.
    """
    @spec repo_state() :: state()
    def repo_state do
      case decide(observe()) do
        :not_started -> :not_started
        :observe_transaction -> transaction_result(SdrAgent.Repo.in_transaction?())
        :unavailable -> :unavailable
      end
    end

    # The default identity (U1), well-formed names (malformed) and a stable
    # name (U6); then the registry observation.
    defp decide_shaped(%{
           dynamic: SdrAgent.Repo,
           named_before: named,
           named_after: named,
           ecto_started: ecto_started,
           running: running
         })
         when is_nil(named) or is_pid(named) do
      decide_registry(named, ecto_started, running)
    end

    defp decide_shaped(_observation), do: :unavailable

    # Without :ecto: S1 when the name is free, U3 when it is held. With
    # :ecto: a proper list of non-nil atoms and pids, then the entries.
    defp decide_registry(nil, false, :not_observed), do: :not_started

    defp decide_registry(named, true, running) when is_list(running) do
      case entries(running, []) do
        {:ok, entries} -> decide_entries(named, entries)
        :error -> :unavailable
      end
    end

    defp decide_registry(_named, _ecto_started, _running), do: :unavailable

    # Any pid entry is U2; otherwise the number of SdrAgent.Repo entries.
    defp decide_entries(named, entries) do
      if Enum.any?(entries, &is_pid/1),
        do: :unavailable,
        else: decide_count(named, Enum.count(entries, &(&1 == SdrAgent.Repo)))
    end

    # S2: free and unlisted; S3: held and listed exactly once; U4 (held,
    # unlisted), U5 (free, listed) and U7 (listed more than once) otherwise.
    defp decide_count(nil, 0), do: :not_started
    defp decide_count(named, 1) when is_pid(named), do: :observe_transaction
    defp decide_count(_named, _count), do: :unavailable

    # A proper list, every element a pid or a non-nil atom; an improper tail
    # or any other element is malformed.
    defp entries([], acc), do: {:ok, acc}

    defp entries([entry | rest], acc) when is_pid(entry) or (is_atom(entry) and entry != nil),
      do: entries(rest, [entry | acc])

    defp entries(_malformed, _acc), do: :error
  end
end

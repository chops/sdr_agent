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

    Stage (D-237 S1): RED declarations only. Every function is
    non-permissive: it reads nothing and returns
    `{:error, :not_implemented}`.
    """

    @type observation :: %{
            dynamic: term(),
            named_before: pid() | nil,
            ecto_started: boolean(),
            running: [atom() | pid()] | :not_observed,
            named_after: pid() | nil
          }
    @type decision :: :not_started | :observe_transaction | :unavailable
    @type state :: :not_started | {:started, boolean()} | :unavailable

    @doc "The bounded observation (contract r6 A1). RED: not implemented."
    @spec observe() :: observation() | {:error, :not_implemented}
    def observe, do: red({:error, :not_implemented})

    @doc "The pure decision over one observation (contract r6 A1). RED: not implemented."
    @spec decide(term()) :: decision() | {:error, :not_implemented}
    def decide(_observation), do: red({:error, :not_implemented})

    @doc "The pure validation of the transaction observation. RED: not implemented."
    @spec transaction_result(term()) ::
            {:started, boolean()} | :unavailable | {:error, :not_implemented}
    def transaction_result(_flag), do: red({:error, :not_implemented})

    @doc "The real `repo_state/0` effect (contract r6 A1). RED: not implemented."
    @spec repo_state() :: state() | {:error, :not_implemented}
    def repo_state, do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against the stub
    # (Elixir 1.20 infers literal returns). Read-only: nothing writes the
    # key; removed in GREEN.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end

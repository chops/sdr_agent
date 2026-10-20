defmodule SdrAgent.Repo do
  @moduledoc """
  The application's Ecto/AshPostgres repo.

  It is also the root of identity-key application scopes (ADR-0009 C3-02
  amendment item 1; plan r8 section 2.2): `prepare_transaction/2` wraps a
  transaction function opened while no transaction is open, so that it
  runs in a fresh `SdrAgent.Audit.IdentityKeys.Scope`. A transaction opened
  inside another, and any `Ecto.Multi`, is passed through unchanged (the
  nested one joins the open scope; a standalone Multi has none). `opts` are
  never changed, and a transaction that requests no key issues no extra
  statement.
  """
  use AshPostgres.Repo,
    otp_app: :sdr_agent

  alias SdrAgent.Audit.IdentityKeys.Scope

  @call_options {__MODULE__, :call_options}
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions", "citext"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def prepare_transaction(fun_or_multi, opts) when is_function(fun_or_multi) do
    if in_transaction?(), do: {fun_or_multi, opts}, else: {Scope.root(fun_or_multi), opts}
  end

  def prepare_transaction(multi, opts), do: {multi, opts}

  # The options `with_call_options/2` put in this process, merged under
  # every repo operation's own options (explicit options win).
  if @test_seams do
    # Test builds also report them, per operation, to the observer set in
    # this process by `observe_default_options/1` (C3-02 G3-2b).
    @impl true
    def default_options(operation) do
      options = Process.get(@call_options, [])

      case Process.get({__MODULE__, :default_options_observer}) do
        pid when is_pid(pid) -> send(pid, {:c302_repo_default_options, operation, options})
        _none -> :ok
      end

      options
    end

    @doc false
    # Test builds only: `pid` receives `{:c302_repo_default_options,
    # operation, options}` for every repo operation of this process.
    def observe_default_options(pid) when is_pid(pid),
      do: Process.put({__MODULE__, :default_options_observer}, pid)
  else
    @impl true
    def default_options(_operation), do: Process.get(@call_options, [])
  end

  @doc """
  Runs `fun` with `options` added, in the calling process only, to every
  repo operation that Ecto builds through `default_options/1` (queries such
  as `all/2`, writes and `transaction/2`; not `query/3`, which Ecto SQL runs
  with its own options only). An operation's explicit options win. A
  nested call merges its options over the enclosing ones (the inner value
  of a key wins). The previous set is restored on every exit path (return,
  raise, throw, exit); outside any call nothing is added. Used to pass
  driver options that an Ash call cannot carry (C3-02 G3-2b: the
  definition bootstrap's `deadline:` and `checkout_retries: 0`).
  """
  def with_call_options(options, fun) when is_list(options) and is_function(fun, 0) do
    previous = Process.get(@call_options)
    Process.put(@call_options, Keyword.merge(previous || [], options))

    try do
      fun.()
    after
      if previous, do: Process.put(@call_options, previous), else: Process.delete(@call_options)
    end
  end

  @impl true
  def min_pg_version do
    %Version{major: 18, minor: 2, patch: 0}
  end
end

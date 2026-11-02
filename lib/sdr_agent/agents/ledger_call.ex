defmodule SdrAgent.Agents.LedgerCall do
  @moduledoc """
  One bounded ledger call of the C2-02b2α coordinator
  (`docs/product/r0/c2-02b2-interface.md` section 1a, "The call's bound"),
  with the mechanics of the b1 drain (`SdrAgent.Agents.ProfileSwitchDrain`):

    * the connection is checked out with `queue: false`, and a busy pool is
      retried until the budget is spent, so no checkout is left queued;
    * the transaction has a client-side timeout of the budget plus a small
      slack;
    * before the body and before each of its steps (`fun.(step)`), the
      transaction-local `lock_timeout` and `statement_timeout` are set to
      the budget left at that moment;
    * before commit the budget is checked again: once it is spent, the
      work rolls back as `{:error, :ledger_timeout}` instead of committing.

  The budget is `min(opts[:budget_ms], 2 s)` (2 s when absent). The body
  runs in `SdrAgent.Audit.transaction/1`; it returns `{:ok, value}` to
  commit or `{:error, reason}` to roll everything back. There is no
  detached execution: the call returns before the caller handles anything
  else.

  `attempt/2` (C2-02b2β) runs the same bounded call but reports whether its
  outcome is **known**: `{:ok, value}` (committed), `{:rolled_back, reason}`
  (definitely not committed: the budget was spent before any work, the
  pool stayed busy until then, or the transaction ended through its own
  rollback, so no `COMMIT` was ever sent — the pre-commit budget refusal is
  `{:rolled_back, :ledger_timeout}`), or `{:unknown, reason}` (an exception
  escaped the transaction, e.g. a connection error that may have hit the
  `COMMIT` itself, or a rollback the driver did not acknowledge). `run/2` is
  `attempt/2` with both failures folded into its `{:error, reason}`.

  Test builds only (`config :sdr_agent, :claude_cli_test_seams, true`, a
  compile-time flag): `client_slack_ms:` replaces the 250 ms client-side
  slack of this one call with an integer in 1..30 000 ms, so a test may hold
  a transaction past the default watchdog without losing its connection. It
  widens nothing on the server side (the transaction-local timeouts and the
  pre-commit check still follow the budget) and changes nothing about how an
  outcome is classified. Any other value, and any use of the option in a
  build without the seam, raises `ArgumentError` before any `Repo` work.
  """
  alias SdrAgent.Audit
  alias SdrAgent.Repo

  @max_ms 2_000
  @client_slack_ms 250
  @checkout_retry_ms 10
  @no_connection "connection not available and queuing is disabled"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @doc "Runs `fun` (arity 0, or 1 taking the step function) under one bound."
  def run(fun, opts \\ []) do
    {deadline, result} = attempt_with_deadline(fun, opts)

    case result do
      {:ok, value} -> {:ok, value}
      {:rolled_back, error} -> timeout_or(deadline, error)
      {:unknown, error} -> timeout_or(deadline, error)
    end
  end

  @doc """
  Runs `fun` like `run/2`, reporting a known or unknown outcome:
  `{:ok, value} | {:rolled_back, reason} | {:unknown, reason}` (see the
  moduledoc).
  """
  def attempt(fun, opts \\ []) do
    {_deadline, result} = attempt_with_deadline(fun, opts)
    result
  end

  defp attempt_with_deadline(fun, opts) do
    slack = client_slack_ms!(opts)
    budget = min(Keyword.get(opts, :budget_ms, @max_ms), @max_ms)
    deadline = System.monotonic_time(:millisecond) + budget
    {deadline, bounded(deadline, slack, fun)}
  end

  # One attempt: the budget left at this moment plus the call's slack is the
  # transaction's client-side timeout; a busy pool is retried with the same
  # slack against the same deadline.
  defp bounded(deadline, slack, fun) do
    case remaining(deadline) do
      ms when ms <= 0 ->
        {:rolled_back, :ledger_timeout}

      ms ->
        fn -> audited_body(deadline, fun) end
        |> Repo.transaction(timeout: ms + slack, queue: false)
        |> unwrap_bounded()
    end
  rescue
    error in DBConnection.ConnectionError ->
      if busy?(error.message),
        do: retry_checkout(deadline, slack, fun),
        else: {:unknown, error}

    error in Postgrex.Error ->
      {:unknown, error}
  end

  # No free connection (`queue: false`), or, under a test's shared SQL
  # sandbox, the one connection is in use by another process.
  defp busy?(message),
    do: message == @no_connection or String.starts_with?(message, "could not checkout")

  defp retry_checkout(deadline, slack, fun) do
    Process.sleep(min(@checkout_retry_ms, max(remaining(deadline), 0)))
    bounded(deadline, slack, fun)
  end

  # The client-side slack of this call: the 250 ms default or, in test builds
  # only, the validated `client_slack_ms:` option. An absent key is the
  # default; a present invalid value (`nil` included) is refused, and so is
  # any presence of the option in a build without the seam.
  if @test_seams do
    @max_client_slack_ms 30_000

    defp client_slack_ms!(opts) do
      case Keyword.fetch(opts, :client_slack_ms) do
        :error ->
          @client_slack_ms

        {:ok, ms} when is_integer(ms) and ms >= 1 and ms <= @max_client_slack_ms ->
          ms

        {:ok, other} ->
          raise ArgumentError,
                "client_slack_ms must be an integer in 1..#{@max_client_slack_ms} " <>
                  "(milliseconds), got: #{inspect(other)}"
      end
    end
  else
    defp client_slack_ms!(opts) do
      if Keyword.has_key?(opts, :client_slack_ms) do
        raise ArgumentError,
              "client_slack_ms is a test-only seam and is not accepted in this build"
      end

      @client_slack_ms
    end
  end

  defp audited_body(deadline, fun) do
    fn -> bounded_body(deadline, fun) end
    |> Audit.transaction()
    |> case do
      {:ok, result} -> result
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp bounded_body(deadline, fun) do
    [[lock, statement]] =
      Repo.query!("SELECT current_setting('lock_timeout'), current_setting('statement_timeout')").rows

    step = fn -> rebound(deadline) end

    with :ok <- step.(),
         {:ok, value} <- call(fun, step),
         :ok <- step.() do
      set_timeouts!(lock, statement)
      {:ok, value}
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp call(fun, step) when is_function(fun, 1), do: fun.(step)
  defp call(fun, _step), do: fun.()

  defp rebound(deadline) do
    case remaining(deadline) do
      ms when ms <= 0 ->
        {:error, :ledger_timeout}

      ms ->
        set_timeouts!("#{ms}ms", "#{ms}ms")
        :ok
    end
  end

  defp set_timeouts!(lock, statement) do
    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
      [lock, statement]
    )
  end

  # `{:ok, value}` is the committed body's own result. An `{:error, _}` came
  # back through this call's own `Repo.rollback/1`, so no COMMIT was sent;
  # only the driver's bare `:rollback` (a transaction it rolled back on its
  # own) is not known to be this call's.
  defp unwrap_bounded({:ok, result}), do: result
  defp unwrap_bounded({:error, :rollback}), do: {:unknown, :rollback}

  defp unwrap_bounded({:error, %Ash.Changeset{errors: errors}}),
    do: {:rolled_back, Ash.Error.to_error_class(errors)}

  defp unwrap_bounded({:error, error}), do: {:rolled_back, error}

  # A lock or statement timeout, or a spent budget, is the call's bound.
  defp timeout_or(deadline, error) do
    cond do
      remaining(deadline) <= 0 -> {:error, :ledger_timeout}
      timeout?(error) -> {:error, :ledger_timeout}
      true -> {:error, error}
    end
  end

  defp timeout?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:lock_not_available, :query_canceled]

  defp timeout?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &timeout?/1)
  defp timeout?(%{error: error}), do: timeout?(error)
  defp timeout?(:ledger_timeout), do: true
  defp timeout?(_error), do: false

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
end

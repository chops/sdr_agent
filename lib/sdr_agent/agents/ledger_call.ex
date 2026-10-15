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
  """
  alias SdrAgent.Audit
  alias SdrAgent.Repo

  @max_ms 2_000
  @client_slack_ms 250
  @checkout_retry_ms 10
  @no_connection "connection not available and queuing is disabled"

  @doc "Runs `fun` (arity 0, or 1 taking the step function) under one bound."
  def run(fun, opts \\ []) do
    budget = min(Keyword.get(opts, :budget_ms, @max_ms), @max_ms)
    bounded(System.monotonic_time(:millisecond) + budget, fun)
  end

  defp bounded(deadline, fun) do
    case remaining(deadline) do
      ms when ms <= 0 ->
        {:error, :ledger_timeout}

      ms ->
        fn -> audited_body(deadline, fun) end
        |> Repo.transaction(timeout: ms + @client_slack_ms, queue: false)
        |> unwrap_bounded(deadline)
    end
  rescue
    error in DBConnection.ConnectionError ->
      if busy?(error.message),
        do: retry_checkout(deadline, fun),
        else: timeout_or(deadline, error)

    error in Postgrex.Error ->
      timeout_or(deadline, error)
  end

  # No free connection (`queue: false`), or, under a test's shared SQL
  # sandbox, the one connection is in use by another process.
  defp busy?(message),
    do: message == @no_connection or String.starts_with?(message, "could not checkout")

  defp retry_checkout(deadline, fun) do
    Process.sleep(min(@checkout_retry_ms, max(remaining(deadline), 0)))
    bounded(deadline, fun)
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

  defp unwrap_bounded({:ok, result}, _deadline), do: result

  defp unwrap_bounded({:error, %Ash.Changeset{errors: errors}}, deadline),
    do: timeout_or(deadline, Ash.Error.to_error_class(errors))

  defp unwrap_bounded({:error, error}, deadline), do: timeout_or(deadline, error)

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

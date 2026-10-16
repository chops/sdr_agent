defmodule SdrAgent.ReadDeadline do
  @moduledoc """
  End-to-end budget for authorized metadata aggregates (ADR-0015). A short
  worker includes pool wait, authorization and query work in one deadline.
  Each read owns a transaction with a lowerable SET LOCAL statement timeout;
  cancellation never queues a retry or changes pooled session defaults.
  Errors are closed classifications, never SQL or exception text.
  """

  alias SdrAgent.Accounts.User
  alias SdrAgent.Repo

  @keys [:actor, :count_timeout_ms, :statement_timeout_ms]

  @doc "Run one authorized scalar read within lowerable 2500/2000 ms ceilings."
  def run(opts, fun) do
    started = System.monotonic_time(:millisecond)

    with {:ok, limits} <- limits(opts),
         :ok <- operator(Keyword.get(opts, :actor)) do
      task = Task.async(fn -> transaction(limits, started, fun) end)

      case Task.yield(task, remaining(started, limits.total)) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        {:exit, _} ->
          {:error, :producer_error}
      end
    end
  end

  @doc "Only active tenant-scoped human operators may use a Home source reader."
  def operator(%User{id: id, tenant_id: tenant, status: :active, role: role})
      when is_binary(id) and is_binary(tenant) and role in [:admin, :reviewer, :auditor],
      do: :ok

  def operator(_), do: {:error, :forbidden}

  @doc "Validate explicit limits without querying or silently substituting defaults."
  def limits(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @keys)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      total = Keyword.get(opts, :count_timeout_ms, 2_500)
      statement = Keyword.get(opts, :statement_timeout_ms, 2_000)

      if is_integer(total) and total in 1..2_500 and is_integer(statement) and
           statement in 1..2_000 and statement < total,
         do: {:ok, %{total: total, statement: statement}},
         else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  def limits(_), do: {:error, :invalid_input}

  @doc "Map source errors to the closed metadata-read result vocabulary."
  def classify(%Ash.Error.Forbidden{}), do: :forbidden

  def classify(reason) when reason in [:forbidden, :timeout, :withheld, :invalid_input],
    do: reason

  def classify(error), do: if(timeout?(error), do: :timeout, else: :producer_error)

  defp transaction(limits, started, fun) do
    Repo.transaction(
      fn ->
        budget = remaining(started, limits.total)
        if budget == 0, do: Repo.rollback(:timeout)
        statement = min(limits.statement, budget)
        Repo.query!("SET LOCAL statement_timeout = #{statement}")

        case fun.(budget) do
          {:ok, value} -> value
          {:error, error} -> Repo.rollback(classify(error))
        end
      end,
      timeout: remaining(started, limits.total)
    )
  rescue
    error -> {:error, classify(error)}
  catch
    _kind, _reason -> {:error, :producer_error}
  end

  defp remaining(started, total),
    do: max(0, total - (System.monotonic_time(:millisecond) - started))

  defp timeout?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true

  defp timeout?(%DBConnection.ConnectionError{message: message}),
    do: String.contains?(message, ["timeout", "timed out", "queue"])

  defp timeout?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &timeout?/1)
  defp timeout?(%{error: error}), do: timeout?(error)
  defp timeout?(_), do: false
end

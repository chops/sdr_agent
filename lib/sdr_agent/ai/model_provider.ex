defmodule SdrAgent.AI.ModelProvider do
  @moduledoc """
  Validated and budgeted boundary for structured model decisions.

  Callers provide a Zoi schema with every request. The facade reserves budget
  before invoking the configured provider, validates the provider output, and
  wraps the complete operation in a privacy-aware GenAI span.
  """

  alias SdrAgent.AI.BudgetStore.InMemory
  alias SdrAgent.Telemetry.GenAI

  @type request :: %{
          required(:id) => String.t(),
          required(:run_id) => String.t(),
          required(:operation) => String.t(),
          required(:prompt) => String.t(),
          required(:schema) => Zoi.schema()
        }
  @type result :: map()

  @callback complete(request(), keyword()) :: {:ok, result()} | {:error, term()}

  @doc "Completes one structured model request through the configured provider."
  def complete(request, opts \\ []) when is_map(request) do
    provider = Keyword.get(opts, :provider, Application.fetch_env!(:sdr_agent, :model_provider))
    budget_store = Keyword.get(opts, :budget_store, InMemory)
    provider_options = Keyword.get(opts, :provider_options, [])
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, reservation} <- budget_store.reserve(request.run_id, now) do
      metadata = %{
        id: request.id,
        model: provider_name(provider),
        input: request.prompt
      }

      outcome =
        GenAI.with_span(request.operation, metadata, fn ->
          invoke_and_validate(provider, request, provider_options)
        end)

      :ok = budget_store.settle(reservation, normalize_outcome(outcome))
      outcome
    end
  end

  defp invoke_and_validate(provider, request, provider_options) do
    with {:ok, result} <- provider.complete(request, provider_options),
         {:ok, output} <- validate(request.schema, result.output) do
      {:ok, %{result | output: output}}
    end
  end

  defp validate(schema, output) do
    case Zoi.parse(schema, output) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:validation_failed, errors}}
    end
  end

  defp normalize_outcome({:ok, _result}), do: :ok
  defp normalize_outcome({:error, reason}), do: {:error, reason}

  defp provider_name(provider) do
    provider |> Module.split() |> List.last() |> Macro.underscore()
  end
end

defmodule SdrAgent.AI.ModelProvider do
  @moduledoc """
  Persisted, validated boundary for structured model decisions.

  The facade reserves the daily guard and an S3 `ModelInvocation` before the
  provider starts, marks the call sent, validates every output with Zoi, and
  records completion, failure, or an unknown outcome through `SdrAgent.Agents`.
  """

  alias SdrAgent.Agents
  alias SdrAgent.AI.BudgetStore.InMemory
  alias SdrAgent.Telemetry.GenAI

  @type request :: %{
          required(:id) => String.t(),
          required(:run) => struct(),
          required(:actor) => struct(),
          required(:operation) => String.t(),
          required(:prompt) => String.t(),
          required(:schema) => Zoi.schema(),
          required(:audit) => map()
        }
  @type result :: map()

  @callback prepare(request(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback complete(request(), keyword()) ::
              {:ok, result()} | {:error, term()} | {:unknown, term()}

  @doc "Completes one structured model request and persists its full lifecycle."
  def complete(request, opts \\ []) when is_map(request) do
    provider = Keyword.get(opts, :provider, Application.fetch_env!(:sdr_agent, :model_provider))
    daily_store = Keyword.get(opts, :budget_store, InMemory)
    provider_options = Keyword.get(opts, :provider_options, [])
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, daily} <- daily_store.reserve_daily(now),
         {:ok, provenance} <- provider.prepare(request, provider_options),
         {:ok, invocation} <- reserve(request, provenance),
         {:ok, sent} <- Agents.mark_model_invocation_sent(invocation, actor: request.actor) do
      metadata = %{id: request.id, model: provenance.model_id, input: request.prompt}

      outcome =
        GenAI.with_span(request.operation, metadata, fn ->
          invoke_validate_and_settle(provider, request, sent, provider_options)
        end)

      :ok = daily_store.settle(daily, normalize_outcome(outcome))
      outcome
    end
  end

  defp reserve(request, provenance) do
    attrs =
      request.audit
      |> Map.merge(provenance)
      |> Map.put(:request, request_body(request))
      |> Map.put(:idempotency_key, request.id)

    Agents.reserve_model_invocation(request.run, attrs, actor: request.actor)
  end

  defp invoke_validate_and_settle(provider, request, invocation, provider_options) do
    started = System.monotonic_time(:millisecond)

    case provider_call(provider, request, provider_options) do
      {:ok, result} -> settle_result(request, invocation, result, started)
      {:error, reason} -> fail(invocation, reason, started)
      {:unknown, _reason} -> mark_unknown(invocation)
    end
  end

  defp provider_call(provider, request, provider_options) do
    provider.complete(request, provider_options)
  rescue
    _exception -> {:unknown, :provider_exception}
  catch
    _kind, _reason -> {:unknown, :provider_exit}
  end

  defp settle_result(request, invocation, result, started) do
    latency = elapsed(started)

    case Zoi.parse(request.schema, result.output) do
      {:ok, output} ->
        attrs = %{
          response: result.raw_response,
          parsed_output: output,
          validation_status: :valid,
          validation_errors: [],
          usage: Map.get(result, :usage, empty_usage()),
          latency_ms: latency
        }

        with {:ok, completed} <-
               Agents.complete_model_invocation(invocation, attrs, actor: request.actor) do
          {:ok, Map.put(result, :invocation, completed) |> Map.put(:output, output)}
        end

      {:error, errors} ->
        attrs = %{
          response: result.raw_response,
          parsed_output: result.output,
          validation_status: :invalid,
          validation_errors: Enum.map(errors, &%{"message" => inspect(&1)}),
          error: %{"kind" => "validation_failed"},
          usage: Map.get(result, :usage, empty_usage()),
          latency_ms: latency
        }

        with {:ok, _failed} <-
               Agents.fail_model_invocation(invocation, attrs, actor: request.actor) do
          {:error, {:validation_failed, errors}}
        end
    end
  end

  defp fail(invocation, reason, started) do
    attrs = %{
      error: %{"kind" => "provider_error", "reason" => safe_reason(reason)},
      latency_ms: elapsed(started)
    }

    case Agents.fail_model_invocation(invocation, attrs, actor: actor(invocation)) do
      {:ok, _failed} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp mark_unknown(invocation) do
    case Agents.mark_model_invocation_unknown(invocation, actor: actor(invocation)) do
      {:ok, _unknown} -> {:error, :provider_outcome_unknown}
      {:error, error} -> {:error, error}
    end
  end

  defp actor(invocation),
    do: %SdrAgent.Actor{type: :agent_runtime, tenant_id: invocation.tenant_id}

  defp request_body(request) do
    Jason.encode!(%{
      id: request.id,
      operation: request.operation,
      prompt: request.prompt,
      schema: Zoi.to_json_schema(request.schema)
    })
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_reason(_reason), do: "redacted"

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
  defp normalize_outcome({:ok, _result}), do: :ok
  defp normalize_outcome({:error, reason}), do: {:error, reason}
end

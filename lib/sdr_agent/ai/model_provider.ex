defmodule SdrAgent.AI.ModelProvider do
  @moduledoc """
  Persisted, validated boundary for structured model decisions.

  The facade reserves an S3 `ModelInvocation` before the provider starts —
  which also enforces the per-run and the persisted per-UTC-day limits
  (ADR-0004; `SdrAgent.Agents.reserve_model_invocation/3`) — marks the call
  sent, validates every output with Zoi, and records completion, failure, or
  an unknown outcome through `SdrAgent.Agents`. A refused reservation
  (`{:error, {:budget_exhausted, :daily}}` or the run counter's
  `Ash.Error.Invalid`) never reaches the provider.

  A provider failure that means the reviewed provider configuration drifted
  (a Claude CLI init attestation with another model, version, tools, MCP
  servers or slash commands, or none at all) also opens a critical
  `provider_error` Failure for operator attention, in the same transaction
  as the failed invocation.

  Requests may carry an optional `:input` — the structured data the prompt
  was rendered from — which deterministic providers (the Fake) read instead
  of parsing the prompt.

  Wire-witness correlation (ADR-0005 S12): before the provider runs, the
  facade adds `:witness` — the reserved invocation UUID and the W3C
  `traceparent` of the `gen_ai.*` span, captured in the calling process.
  ClaudeCLI forwards both to its child only; other providers ignore them.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Repo
  alias SdrAgent.Telemetry.GenAI

  @drift [
    :missing_init_attestation,
    :model_attestation_drift,
    :version_attestation_drift,
    :tool_attestation_drift,
    :mcp_attestation_drift,
    :slash_command_attestation_drift
  ]

  @type request :: %{
          required(:id) => String.t(),
          required(:run) => struct(),
          required(:actor) => struct(),
          required(:operation) => String.t(),
          required(:prompt) => String.t(),
          required(:schema) => Zoi.schema(),
          required(:audit) => map(),
          optional(:input) => map(),
          optional(:witness) => %{model_invocation_id: String.t(), traceparent: String.t() | nil}
        }
  @type result :: map()

  @callback prepare(request(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback complete(request(), keyword()) ::
              {:ok, result()} | {:error, term()} | {:unknown, term()}

  @doc "Completes one structured model request and persists its full lifecycle."
  def complete(request, opts \\ []) when is_map(request) do
    provider = Keyword.get(opts, :provider, Application.fetch_env!(:sdr_agent, :model_provider))
    provider_options = Keyword.get(opts, :provider_options, [])

    with {:ok, provenance} <- provider.prepare(request, provider_options),
         {:ok, invocation} <- reserve(request, provenance),
         {:ok, sent} <- Agents.mark_model_invocation_sent(invocation, actor: request.actor) do
      metadata = %{id: request.id, model: provenance.model_id, input: request.prompt}

      GenAI.with_span(request.operation, metadata, fn ->
        # Captured here, in the caller's process inside the gen_ai span and
        # before any serialized provider hop (ADR-0005 S12 amendment).
        witness = %{model_invocation_id: sent.id, traceparent: GenAI.traceparent()}

        invoke_validate_and_settle(
          provider,
          Map.put(request, :witness, witness),
          sent,
          provider_options
        )
      end)
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

    actor = actor(invocation)

    Audit.transaction(fn ->
      with {:ok, failed} <- Agents.fail_model_invocation(invocation, attrs, actor: actor),
           {:ok, _failure} <- attention(failed, reason, actor) do
        failed
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, _failed} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp attention(invocation, reason, actor) when reason in @drift do
    Operations.open_failure(
      %{
        subject_resource: inspect(invocation.__struct__),
        subject_id: invocation.id,
        class: :provider_error,
        severity: :critical,
        message:
          "model provider #{invocation.provider} attestation failed: #{reason}; " <>
            "calls stay refused until the reviewed configuration is restored",
        retryable: false
      },
      actor: actor
    )
  end

  defp attention(_invocation, _reason, _actor), do: {:ok, :none}

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
end

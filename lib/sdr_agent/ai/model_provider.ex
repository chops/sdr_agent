defmodule SdrAgent.AI.ModelProvider do
  @moduledoc """
  Persisted, validated boundary for structured model decisions.

  The facade reserves an S3 `ModelInvocation` before the provider starts —
  which also enforces the per-run and the persisted per-UTC-day limits
  (ADR-0004; `SdrAgent.Agents.reserve_model_invocation/3`) — validates every
  output with Zoi, and records completion, failure, or an unknown outcome
  through `SdrAgent.Agents`.

  The sent boundary (C9-03): for the Fake (and any in-process provider) the
  facade marks the call sent before the provider runs, as before. For
  ClaudeCLI it does not: it hands the provider the reserved invocation id
  (`:witness`), the row stays `reserved` while the call is queued, and the
  ClaudeCLI server marks it sent through `SdrAgent.Agents.admit_launch/3`
  just before it opens the port. The facade then re-reads the row before
  settling: a sent row settles as before (completed, failed, or unknown); a
  row the server's launch admission already failed is returned as that
  refusal without another write; a row still `reserved` was never launched
  (sent always precedes the port), so it is failed — never sent — whatever
  the provider answered (a result without launch admission is
  `{:error, :launch_not_admitted}`). A refused reservation
  (`{:error, {:budget_exhausted, :daily}}`, the run counter's
  `Ash.Error.Invalid`, or for ClaudeCLI a C9 grant refusal returned as
  `{:error, %SdrAgent.Agents.Admission.Refused{reason: :no_eligible_grant,
  failure_id: ..., event_id: ..., agent_run_id: ..., request_id: ...}}`,
  whose operator-attention Failure is already committed)
  never reaches the provider. The provider's `prepare/2` provenance carries
  the call's `profile_id`.

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
  alias SdrAgent.AI.JsonSchema
  alias SdrAgent.AI.ModelProvider.Runtime
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

  @doc """
  Completes one structured model request and persists its full lifecycle.
  The provider (`:provider`, default: the runtime selection) and its
  `:provider_options` are resolved by `SdrAgent.AI.ModelProvider.Runtime`
  first: an absent or unhealthy ClaudeCLI is refused before any
  reservation.
  """
  def complete(request, opts \\ []) when is_map(request) do
    with {:ok, model} <- Runtime.resolve(Keyword.take(opts, [:provider, :provider_options])) do
      run(request, model[:provider], Keyword.get(model, :provider_options, []))
    end
  end

  defp run(request, provider, provider_options) do
    with {:ok, provenance} <- provider.prepare(request, provider_options),
         {:ok, invocation} <- reserve(request, provenance),
         {:ok, invocation} <- before_call(invocation, request) do
      metadata = %{id: request.id, model: provenance.model_id, input: request.prompt}

      GenAI.with_span(request.operation, metadata, fn ->
        # Captured here, in the caller's process inside the gen_ai span and
        # before any serialized provider hop (ADR-0005 S12 amendment). For
        # ClaudeCLI it also names the reserved invocation the server admits.
        witness = %{model_invocation_id: invocation.id, traceparent: GenAI.traceparent()}

        invoke_validate_and_settle(
          provider,
          Map.put(request, :witness, witness),
          invocation,
          provider_options
        )
      end)
    end
  end

  # C9-03: a ClaudeCLI call is sent only by the server's launch admission.
  defp before_call(%{provider: :claude_cli} = invocation, _request), do: {:ok, invocation}

  defp before_call(invocation, request),
    do: Agents.mark_model_invocation_sent(invocation, actor: request.actor)

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
    outcome = provider_call(provider, request, provider_options)

    with {:ok, invocation} <- current(invocation) do
      settle(outcome, request, invocation, started)
    end
  end

  # ClaudeCLI's row may have been sent or failed by the server's launch
  # admission meanwhile: it is re-read before settling. The Fake's is sent.
  defp current(%{provider: :claude_cli} = invocation),
    do: Agents.get_model_invocation(invocation.id, actor: actor(invocation))

  defp current(invocation), do: {:ok, invocation}

  defp settle(outcome, request, %{status: :sent} = invocation, started) do
    case outcome do
      {:ok, result} -> settle_result(request, invocation, result, started)
      {:error, reason} -> fail(invocation, reason, started)
      {:unknown, _reason} -> mark_unknown(invocation)
    end
  end

  # Never launched: the server sends before it opens the port.
  defp settle(outcome, _request, %{status: :reserved} = invocation, started) do
    reason =
      case outcome do
        {:ok, _result} -> :launch_not_admitted
        {:error, reason} -> reason
        {:unknown, reason} -> reason
      end

    fail(invocation, reason, started)
  end

  # Already terminal — failed by launch admission (with its Failure), or
  # settled by crash recovery meanwhile: nothing more is written.
  defp settle({:error, reason}, _request, _terminal, _started), do: {:error, reason}
  defp settle(_outcome, _request, _terminal, _started), do: {:error, :invocation_already_settled}

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

  @doc """
  The stored request body of `request`: JSON of its `id`, `operation`,
  `prompt` and rendered output `schema`. Its SHA-256 is the invocation's
  `request_sha256`; the calibration console stores its request with this
  same serialization (R0-07 packet 8.13).
  """
  def request_body(request) do
    Jason.encode!(%{
      id: request.id,
      operation: request.operation,
      prompt: request.prompt,
      schema: JsonSchema.render(request.schema)
    })
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_reason(_reason), do: "redacted"

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end

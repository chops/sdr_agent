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

  ## Provider outcomes (R0-04, `docs/product/r0/r0-04-seam.md`)

  `prepare/2` must return `{:ok, provenance_map}` or `{:error, reason}`.
  Anything else gives `{:error, :malformed_provider_prepare}`, with nothing
  reserved or charged.

  `complete/2` may return exactly one of three replies:
    * **success:** `{:ok, %{output: _, raw_response: binary}}`, optionally
      with `:usage`. A present `:usage` must be a plain map with exactly
      `input_tokens`, `output_tokens` and `plan_calls`, none nil, which
      casts to `SdrAgent.Agents.ModelInvocation.Usage`; it is stored
      normalized. An omitted `:usage` keeps the default.
    * **known failure:** `{:error, reason}`.
    * **unknown:** `{:unknown, reason}`, or a raise or exit.

  Any other reply is malformed. It is checked before any settlement write
  and settled by the re-read row's state, which takes precedence:
    * a `sent` row becomes unknown (`{:error, :provider_outcome_unknown}`),
      because the call may have reached the provider. It is never
      retried;
    * a `reserved` row (never launched) is failed with
      `:launch_not_admitted`, never sent. Valid replies keep their reasons
      as before;
    * a terminal row gets no write (`{:error, :invocation_already_settled}`).

  A success completes only if Zoi accepts the output and the parsed value
  is a map. `parsed_output` is a map, so a non-map output is failed as
  `validation_failed`, with no parsed output and one entry naming only its
  type. Only provider and protocol outcomes are normalized: an error from
  settlement itself (database, authorization, audit) comes back as that
  error.

  Requests may carry an optional `:input` — the structured data the prompt
  was rendered from — which deterministic providers (the Fake) read instead
  of parsing the prompt.

  Wire-witness correlation (ADR-0005 S12): before the provider runs, the
  facade adds `:witness` — the reserved invocation UUID and the W3C
  `traceparent` of the `gen_ai.*` span, captured in the calling process.
  ClaudeCLI forwards both to its child only; other providers ignore them.
  """

  alias SdrAgent.AgentEnv.OperationSnapshot
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
          optional(:content_capture) => :inherit | :off,
          optional(:witness) => %{model_invocation_id: String.t(), traceparent: String.t() | nil}
        }
  @type result :: map()

  @doc """
  The call's provenance (provider, `profile_id`, model and version fields),
  read before reservation. `{:error, reason}` refuses the call; any other
  return is `:malformed_provider_prepare`.
  """
  @callback prepare(request(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Performs the call. `{:ok, %{output, raw_response}}` (optional `:usage`)
  is a reply to validate; `{:error, reason}` is a known failure;
  `{:unknown, reason}` means the outcome is not known, and the call is
  never repeated. Anything else is treated as malformed (see the module
  doc).
  """
  @callback complete(request(), keyword()) ::
              {:ok, result()} | {:error, term()} | {:unknown, term()}

  @doc """
  Completes one structured model request and persists its full lifecycle.
  The provider (`:provider`, default: the runtime selection) and its
  `:provider_options` are resolved by `SdrAgent.AI.ModelProvider.Runtime`
  first: an absent or unhealthy ClaudeCLI is refused before any
  reservation.

  C2* operation snapshot entry `:model_provider_complete` (ADR-0005 C2*
  item 2): inherits under an action; a direct top-level call owns.
  """
  def complete(request, opts \\ []) when is_map(request) do
    OperationSnapshot.enter(:model_provider_complete, fn ->
      with {:ok, model} <- Runtime.resolve(Keyword.take(opts, [:provider, :provider_options])) do
        run(request, model[:provider], Keyword.get(model, :provider_options, []))
      end
    end)
  end

  defp run(request, provider, provider_options) do
    with {:ok, provenance} <- prepare(provider, request, provider_options),
         {:ok, invocation} <- reserve(request, provenance),
         {:ok, invocation} <- before_call(invocation, request) do
      metadata = span_metadata(request, provenance)

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

  # R0-04-3: only `{:ok, map}` or `{:error, reason}` reaches reservation.
  defp prepare(provider, request, provider_options) do
    case provider.prepare(request, provider_options) do
      {:ok, provenance} when is_map(provenance) and not is_struct(provenance) -> {:ok, provenance}
      {:error, _reason} = error -> error
      _malformed -> {:error, :malformed_provider_prepare}
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
    outcome = provider |> provider_call(request, provider_options) |> envelope()

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
      :malformed -> mark_unknown(invocation)
    end
  end

  # Never launched: the server sends before it opens the port.
  defp settle(outcome, _request, %{status: :reserved} = invocation, started) do
    reason =
      case outcome do
        {:ok, _result} -> :launch_not_admitted
        {:error, reason} -> reason
        {:unknown, reason} -> reason
        :malformed -> :launch_not_admitted
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

  # R0-04-1: the closed reply envelope, checked before any settlement
  # write. A success needs a map with `:output` and a binary
  # `:raw_response`; a present `:usage` must be a plain map with exactly the
  # three counters, none nil, that casts to the embedded type (whose
  # constraints refuse negatives). Anything else is `:malformed`.
  @usage_keys [:input_tokens, :output_tokens, :plan_calls]

  defp envelope({:ok, %{output: _, raw_response: raw} = result})
       when is_binary(raw) and not is_struct(result) do
    case Map.fetch(result, :usage) do
      :error ->
        {:ok, Map.put(result, :usage, empty_usage())}

      {:ok, usage} ->
        case usage(usage) do
          {:ok, usage} -> {:ok, Map.put(result, :usage, usage)}
          :error -> :malformed
        end
    end
  end

  defp envelope({:error, _reason} = error), do: error
  defp envelope({:unknown, _reason} = unknown), do: unknown
  defp envelope(_other), do: :malformed

  defp usage(usage) when is_map(usage) and not is_struct(usage) do
    with true <- Enum.sort(Map.keys(usage)) == Enum.sort(@usage_keys),
         true <- Enum.all?(@usage_keys, &(not is_nil(Map.fetch!(usage, &1)))),
         {:ok, cast} <- Ash.Type.cast_input(SdrAgent.Agents.ModelInvocation.Usage, usage, []),
         {:ok, cast} <-
           Ash.Type.apply_constraints(SdrAgent.Agents.ModelInvocation.Usage, cast, []) do
      {:ok, Map.take(cast, @usage_keys)}
    else
      _invalid -> :error
    end
  end

  defp usage(_usage), do: :error

  defp settle_result(request, invocation, result, started) do
    latency = elapsed(started)

    case Zoi.parse(request.schema, result.output) do
      {:ok, output} when not is_map(output) or is_struct(output) ->
        not_object(request, invocation, result, output, [], latency)

      {:error, errors} when not is_map(result.output) or is_struct(result.output) ->
        not_object(request, invocation, result, result.output, errors, latency)

      {:ok, output} ->
        attrs = %{
          response: result.raw_response,
          parsed_output: output,
          validation_status: :valid,
          validation_errors: [],
          usage: result.usage,
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
          usage: result.usage,
          latency_ms: latency
        }

        with {:ok, _failed} <-
               Agents.fail_model_invocation(invocation, attrs, actor: request.actor) do
          {:error, {:validation_failed, errors}}
        end
    end
  end

  # R0-04-2: `parsed_output` is a map, so an output that is not one, valid
  # or not, is failed as `validation_failed` with no parsed output and one
  # entry naming only its type (never its value).
  defp not_object(request, invocation, result, output, errors, latency) do
    type_entry = %{"message" => "output is not an object", "type" => type_name(output)}

    attrs = %{
      response: result.raw_response,
      parsed_output: nil,
      validation_status: :invalid,
      validation_errors: Enum.map(errors, &%{"message" => inspect(&1)}) ++ [type_entry],
      error: %{"kind" => "validation_failed"},
      usage: result.usage,
      latency_ms: latency
    }

    with {:ok, _failed} <- Agents.fail_model_invocation(invocation, attrs, actor: request.actor) do
      {:error, {:validation_failed, errors ++ [type_entry]}}
    end
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(nil), do: "nil"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(_value), do: "other"

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

  if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
    alias SdrAgent.AI.ModelProvider.CalibrationCall
    alias SdrAgent.AI.ModelProvider.ClaudeCLI

    @doc """
    Test-seam builds only (R0-07 packet 8.14.3, d3b): calls an invocation the
    calibration console already reserved, through the private ClaudeCLI
    server `opts[:server]`, and settles it exactly as `complete/2` does.

    The target is checked first (`CalibrationCall.target/3`): anything
    invalid is `{:error, :calibration_call_invalid}` with no provider call,
    no witness and no write. Then, as in `complete/2`, the witness is
    captured in this process inside the `gen_ai` span and the shared
    provider call, re-read and settlement run unchanged (`sent` only by the
    server's launch admission).
    """
    def calibration_call(request, invocation_id, opts) do
      provider_options = Keyword.take(opts, [:server])

      case CalibrationCall.target(request, invocation_id, provider_options) do
        {:ok, invocation, provenance} ->
          metadata = span_metadata(request, provenance)

          GenAI.with_span(request.operation, metadata, fn ->
            witness = %{model_invocation_id: invocation.id, traceparent: GenAI.traceparent()}

            invoke_validate_and_settle(
              ClaudeCLI,
              Map.put(request, :witness, witness),
              invocation,
              provider_options
            )
          end)

        :invalid ->
          {:error, :calibration_call_invalid}
      end
    end
  end

  # C4: the request's `content_capture` (`:off` for input that carries run
  # settings) decides the span's content events; provider options cannot
  # turn capture back on.
  defp span_metadata(request, provenance) do
    %{
      id: request.id,
      model: provenance.model_id,
      input: request.prompt,
      content_capture: content_capture(request)
    }
  end

  defp content_capture(request) do
    case Map.get(request, :content_capture, :inherit) do
      :inherit -> :inherit
      _off -> :off
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({kind, _value}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_reason(_reason), do: "redacted"

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}
  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end

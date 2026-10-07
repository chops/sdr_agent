defmodule SdrAgent.Agents.Witness do
  @moduledoc """
  Wire-witness reconciliation of terminal ClaudeCLI invocations against the
  independent local proxy store (S12 step 6; ADR-0005 S12 amendment; entity
  conditions C1–C8, plan P1/P2/P7).

  `reconcile/2` (REC only):

    1. reads the invocation's exchanges with the bounded, read-only
       `SdrAgent.Agents.Witness.Store` and — only when a message exchange
       exists — the stored application bodies through the audited, scoped
       `SdrAgent.Agents.read_reconciliation_payloads/2`. File I/O and these
       reads happen before any database lock;
    2. classifies every observed exchange: exactly one complete
       `/v1/messages` exchange is the `primary` (several are `ambiguous`); a
       complete `count_tokens` exchange whose response has no content is
       `ancillary`; everything else — unknown routes, open start markers,
       other count_tokens — is `unclassified`. The primary is compared with
       `SdrAgent.Agents.Witness.Projection`; unsupported proxy versions,
       content encodings, incomplete captures and bad blobs never reach a
       comparison;
    3. in one transaction that first locks the invocation row, appends
       `WireWitnessLink`s (only changed observations: a replay is a no-op; a
       same-version mismatch is never superseded) and keeps operator
       attention current: at most one live critical Failure (mismatch) and
       one live warning (missing, open, ambiguous, unclassified,
       unsupported, unreadable store) per invocation, resolving a warning
       whose condition changed or cleared. An unreadable inventory
       downgrades current non-mismatch links with an `inferred` successor.

  A match is `reconciled` only for a method in the runtime allowlist
  (`reconciled_methods`, shipped empty — R3); otherwise `inferred` with
  `method_not_enabled`. A per-call `:methods` override is honoured only when
  `allow_method_override` is configured (test configuration only). The
  model is never called again.

  `status/1` (used by `SdrAgent.Agents.witness_status/2`) is the C1
  invocation answer over current links. `enqueue/2` writes a
  `reconcile_model` Operation and its Oban job in one transaction.
  Configuration: `config :sdr_agent, SdrAgent.Agents.Witness, store_root:,
  reconciled_methods:, allow_method_override:` (`store_root: nil` keeps
  reconciliation inert).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.Witness.ReconcileWorker
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  @method :propagated_id
  @proxy_versions ["0.2.0"]
  @terminal [:completed, :failed, :unknown]
  @messages "/anthropic/v1/messages"
  @count_tokens "/anthropic/v1/messages/count_tokens"
  @subject "SdrAgent.Agents.ModelInvocation"
  @max_generations 4

  ## Configuration

  @doc "The configured proxy blob directory, or nil (reconciliation inert)."
  def store_root, do: Keyword.get(config(), :store_root)

  @doc "Methods whose matching proof may be labelled reconciled (ships empty)."
  def reconciled_methods, do: Keyword.get(config(), :reconciled_methods, [])

  defp config, do: Application.get_env(:sdr_agent, __MODULE__, [])

  ## Reconciliation

  @doc """
  Reconciles one invocation (REC). Options: `actor:`, `store_root:`
  (default `store_root/0`), `methods:` (test-only override). Returns
  `{:ok, %{status:, links:, attention:}}`, `{:ok, %{status: :skipped}}` when
  unconfigured or not a terminal ClaudeCLI invocation, or `{:error, reason}`.
  """
  def reconcile(invocation_id, opts) do
    actor = Keyword.get(opts, :actor)
    meta = %{resource: Agents.WireWitnessLink, action: :reconcile, subject_id: invocation_id}

    Guard.run(meta, actor, fn ->
      with :ok <- authorize(actor),
           {:ok, methods} <- methods(opts),
           {:ok, hook} <- test_hook(opts) do
        root = Keyword.get(opts, :store_root, store_root())
        do_reconcile(invocation_id, root, methods, actor, hook)
      end
    end)
  end

  defp do_reconcile(_invocation_id, nil, _methods, _actor, _hook), do: {:ok, %{status: :skipped}}

  defp do_reconcile(invocation_id, root, methods, actor, hook) do
    with {:ok, invocation} <- GuardedCall.get(ModelInvocation, invocation_id, actor: actor),
         :ok <- eligible(invocation),
         {:ok, observation} <- observe(invocation, root, actor, hook) do
      persist(invocation, observation, methods, actor)
    else
      :skip -> {:ok, %{status: :skipped}}
      other -> other
    end
  end

  defp eligible(%{provider: :claude_cli, status: status}) when status in @terminal, do: :ok
  defp eligible(_invocation), do: :skip

  defp authorize(%Actor{type: :reconciler, tenant_id: tenant_id}) when is_binary(tenant_id),
    do: :ok

  defp authorize(_actor), do: {:error, Ash.Error.Forbidden.exception([])}

  # Test-only hook run after the observation, before persistence (stale
  # observation tests); refused unless test overrides are configured.
  defp test_hook(opts) do
    case Keyword.fetch(opts, :after_observe) do
      :error ->
        {:ok, fn -> :ok end}

      {:ok, hook} when is_function(hook, 0) ->
        if overrides?(), do: {:ok, hook}, else: {:error, :method_override_forbidden}

      {:ok, _other} ->
        {:error, :invalid_option}
    end
  end

  defp overrides?, do: Keyword.get(config(), :allow_method_override, false)

  defp methods(opts) do
    case Keyword.fetch(opts, :methods) do
      :error ->
        {:ok, reconciled_methods()}

      {:ok, methods} ->
        if Keyword.get(config(), :allow_method_override, false),
          do: {:ok, methods},
          else: {:error, :method_override_forbidden}
    end
  end

  ## Observation (no database locks held)

  defp observe(invocation, root, actor, hook) do
    fingerprint = Store.fingerprint(root, invocation.id)

    result =
      case Store.inventory(root, invocation.id) do
        {:ok, %{exchanges: exchanges}} ->
          evaluate(invocation, root, exchanges, actor)

        {:error, reason} ->
          reason = Atom.to_string(reason)
          {:ok, %{error: reason, exchanges: [], warnings: [reason]}}
      end

    hook.()

    with {:ok, observation} <- result,
         do: {:ok, Map.merge(observation, %{root: root, fingerprint: fingerprint})}
  end

  defp evaluate(invocation, root, exchanges, actor) do
    primaries =
      Enum.filter(exchanges, &(&1.state == :terminal and &1.record["route"] == @messages))

    with {:ok, app} <- app_payloads(primaries, invocation, actor) do
      inventory = inventory_digest(exchanges)

      evaluated =
        Enum.map(exchanges, fn exchange ->
          exchange
          |> classify(length(primaries), invocation, root, app)
          |> Map.merge(%{exchange: exchange, inventory: inventory})
        end)

      warnings =
        Enum.flat_map(evaluated, & &1.warnings) ++
          if(primaries == [], do: ["no_primary_exchange"], else: [])

      {:ok, %{error: nil, exchanges: evaluated, warnings: Enum.uniq(warnings)}}
    end
  end

  defp app_payloads([], _invocation, _actor), do: {:ok, nil}

  defp app_payloads(_primaries, invocation, actor),
    do: Agents.read_reconciliation_payloads(invocation, actor: actor)

  defp classify(%{state: :open}, _primaries, _invocation, _root, _app),
    do: result(:inferred, "unclassified", ["exchange_open"], warn: true)

  defp classify(
         %{record: %{"route" => @count_tokens} = record},
         _primaries,
         _invocation,
         root,
         _app
       ) do
    with nil <- gate(record),
         {:ok, body} <- Store.blob(root, record["response_sha256"]),
         {:ok, %{"input_tokens" => tokens} = response} when is_integer(tokens) <-
           Jason.decode(body),
         true <- Map.keys(response) == ["input_tokens"] do
      result(:inferred, "ancillary", [], [])
    else
      reason when is_binary(reason) ->
        result(:inferred, "unclassified", ["unclassified_exchange", reason], warn: true)

      _ ->
        result(:inferred, "unclassified", ["unclassified_exchange"], warn: true)
    end
  end

  defp classify(%{record: %{"route" => @messages}}, primaries, _invocation, _root, _app)
       when primaries > 1,
       do: result(:inferred, "ambiguous", ["multiple_primary_exchanges"], warn: true)

  defp classify(%{record: %{"route" => @messages} = record}, 1, invocation, root, app),
    do: primary(record, invocation, root, app)

  defp classify(_exchange, _primaries, _invocation, _root, _app),
    do: result(:inferred, "unclassified", ["unclassified_exchange"], warn: true)

  defp primary(record, invocation, root, app) do
    with nil <- gate(record),
         {:ok, request} <- Store.blob(root, record["request_sha256"]),
         {:ok, response} <- Store.blob(root, record["response_sha256"]) do
      project(Projection.compare(invocation, app, request, response))
    else
      reason when is_binary(reason) -> result(:inferred, "primary", [reason], warn: true)
      {:error, reason} -> result(:inferred, "primary", [blob_reason(reason)], warn: true)
    end
  end

  defp blob_reason(reason) do
    reason = Atom.to_string(reason)
    if String.starts_with?(reason, "blob_"), do: reason, else: "blob_" <> reason
  end

  # Gates every terminal exchange must pass before it can count: a reviewed
  # proxy version, no content encoding, a complete capture.
  defp gate(record) do
    cond do
      record["proxy_version"] not in @proxy_versions -> "proxy_version_unsupported"
      is_binary(record["response_content_encoding"]) -> "content_encoding_unsupported"
      not complete?(record) -> "capture_incomplete"
      true -> nil
    end
  end

  defp project({:match, proof}),
    do: %{
      result(:match, "primary", [], [])
      | digests: proof.digests,
        projection: Projection.version()
    }

  defp project({:mismatch, proof}) do
    %{
      result(:mismatch, "primary", proof.reasons, [])
      | digests: proof.digests,
        projection: Projection.version()
    }
  end

  defp project({:unsupported, proof}) do
    %{
      result(:inferred, "primary", proof.reasons, warn: true)
      | digests: proof.digests,
        projection: Projection.version()
    }
  end

  defp result(status, classification, reasons, opts) do
    %{
      status: status,
      classification: classification,
      reasons: reasons,
      warnings: if(Keyword.get(opts, :warn, false), do: reasons, else: []),
      digests: %{},
      projection: nil
    }
  end

  defp complete?(record) do
    record["outcome"] == "complete" and record["http_status"] == 200 and
      record["request_capture_complete"] == true and record["response_capture_complete"] == true and
      is_binary(record["request_sha256"]) and is_binary(record["response_sha256"]) and
      (record["route"] != @messages or record["stream_complete"] == true)
  end

  defp inventory_digest(exchanges) do
    exchanges
    |> Enum.map(&[&1.record_id, Atom.to_string(&1.state), &1.record["outcome"]])
    |> Enum.sort()
    |> Canonical.encode!()
    |> then(&(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower)))
  end

  ## Persistence (one transaction; invocation row lock first)

  defp persist(invocation, observation, methods, actor) do
    Audit.transaction(fn ->
      with {:ok, _locked} <- lock(invocation),
           :ok <- fresh(invocation, observation),
           {:ok, current} <- Agents.current_wire_witness_links(invocation.id, actor: actor),
           :ok <- write_links(invocation, observation, current, methods, actor),
           {:ok, links} <- Agents.current_wire_witness_links(invocation.id, actor: actor),
           :ok <- attention(invocation, links, observation.warnings, actor) do
        %{status: status(links), links: links, attention: observation.warnings}
      else
        :stale -> %{status: :stale, links: [], attention: []}
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # Under the invocation lock, a metadata-only re-check (lstat of at most 64
  # entries, no content read) that the store still holds what was observed;
  # an older observation must not overwrite the outcome of a newer one.
  defp fresh(invocation, %{root: root, fingerprint: fingerprint}) do
    if Store.fingerprint(root, invocation.id) == fingerprint, do: :ok, else: :stale
  end

  defp lock(invocation) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(id == ^invocation.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  defp write_links(invocation, %{error: nil, exchanges: exchanges}, current, methods, actor) do
    heads = Map.new(current, &{&1.proxy_record_ref, &1})
    observed = MapSet.new(exchanges, & &1.exchange.record_id)

    observed_writes =
      Enum.map(exchanges, fn evaluated ->
        desired = desired_link(invocation, evaluated, methods)
        {Map.get(heads, desired.proxy_record_ref), desired, "reconciliation_rerun"}
      end)

    # An exchange linked before but absent from the current inventory can no
    # longer support assurance: downgrade it (mismatches are kept).
    vanished_writes =
      for head <- current, not MapSet.member?(observed, head.proxy_record_ref) do
        {head, downgraded(head, "exchange_missing"), "exchange_missing"}
      end

    put_all(observed_writes ++ vanished_writes, actor)
  end

  # An unreadable inventory: downgrade every current non-mismatch link.
  defp write_links(_invocation, %{error: reason}, current, _methods, actor) do
    current
    |> Enum.map(&{&1, downgraded(&1, reason), "store_unreadable"})
    |> put_all(actor)
  end

  defp put_all(writes, actor) do
    Enum.reduce_while(writes, :ok, fn {head, desired, reason}, :ok ->
      case put_link(head, desired, reason, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp downgraded(head, reason) do
    evidence =
      head.evidence
      |> Map.delete("supersede_reason")
      |> Map.delete("projection_version")
      |> Map.put(
        "reason_codes",
        Enum.take(Enum.uniq([reason | head.evidence["reason_codes"] || []]), 16)
      )

    %{
      model_invocation_id: head.model_invocation_id,
      proxy_record_ref: head.proxy_record_ref,
      proxy_request_sha256: head.proxy_request_sha256,
      proxy_response_sha256: head.proxy_response_sha256,
      link_status: :inferred,
      method: head.method,
      evidence: evidence
    }
  end

  defp put_link(nil, desired, _reason, actor), do: Agents.link_wire_witness(desired, actor: actor)

  defp put_link(head, desired, reason, actor) do
    cond do
      same?(head, desired) ->
        {:ok, :unchanged}

      # C3: only an evaluated, different projection may correct a mismatch;
      # weaker or unsupported observations (no projection) never do.
      head.link_status == :mismatch and
          (not is_binary(desired.evidence["projection_version"]) or
             head.evidence["projection_version"] == desired.evidence["projection_version"]) ->
        {:ok, :mismatch_kept}

      true ->
        desired
        |> Map.put(:supersedes_id, head.id)
        |> Map.update!(:evidence, &Map.put(&1, "supersede_reason", reason))
        |> Agents.link_wire_witness(actor: actor)
    end
  end

  defp same?(head, desired) do
    head.link_status == desired.link_status and head.method == desired.method and
      head.proxy_request_sha256 == desired.proxy_request_sha256 and
      head.proxy_response_sha256 == desired.proxy_response_sha256 and
      Map.delete(head.evidence, "supersede_reason") == desired.evidence
  end

  defp desired_link(invocation, evaluated, methods) do
    %{exchange: %{record_id: record_id, record: record}} = evaluated

    {status, reasons} =
      case evaluated.status do
        :match ->
          if @method in methods,
            do: {:reconciled, evaluated.reasons},
            else: {:inferred, ["method_not_enabled" | evaluated.reasons]}

        other ->
          {other, evaluated.reasons}
      end

    %{
      model_invocation_id: invocation.id,
      proxy_record_ref: record_id,
      proxy_request_sha256: decode_hex(record["request_sha256"]),
      proxy_response_sha256: decode_hex(record["response_sha256"]),
      link_status: status,
      method: @method,
      evidence: evidence(invocation, evaluated, record, reasons)
    }
  end

  defp evidence(invocation, evaluated, record, reasons) do
    candidate =
      %{
        "witness_schema" => record["schema_version"],
        "proxy_version" => record["proxy_version"],
        "cli_version" => invocation.provider_version,
        "route" => record["route"],
        "http_method" => record["method"],
        "http_status" => record["http_status"],
        "outcome" => record["outcome"],
        "started_at" => record["started_at"],
        "completed_at" => record["completed_at"],
        "request_bytes_seen" => record["request_bytes_seen"],
        "response_bytes_seen" => record["response_bytes_seen"],
        "request_capture_complete" => record["request_capture_complete"],
        "response_capture_complete" => record["response_capture_complete"],
        "stream_complete" => record["stream_complete"],
        "response_content_encoding" => record["response_content_encoding"],
        "classification" => evaluated.classification,
        "projection_version" => evaluated.projection,
        "app_request_sha256" => hex(invocation.request_sha256),
        "app_response_sha256" => hex(invocation.response_sha256),
        "inventory_sha256" => evaluated.inventory,
        "reason_codes" => reasons |> Enum.uniq() |> Enum.take(16)
      }
      |> Map.merge(evaluated.digests)

    # Untrusted proxy metadata: keep only values the allowlist accepts.
    candidate
    |> Enum.filter(fn {key, value} ->
      not is_nil(value) and match?({:ok, _}, WitnessEvidence.validate(%{key => value}))
    end)
    |> Map.new()
  end

  ## Attention (same transaction)

  defp attention(invocation, links, warnings, actor) do
    with {:ok, live} <- live_failures(invocation) do
      critical? = Enum.any?(links, &(&1.link_status == :mismatch))
      warnings = if critical?, do: [], else: Enum.sort(warnings)
      {criticals, live_warnings} = Enum.split_with(live, &(&1.severity == :critical))

      with :ok <- ensure_critical(critical?, criticals, invocation, actor) do
        ensure_warning(warnings, live_warnings, invocation, actor)
      end
    end
  end

  defp ensure_critical(true, [], invocation, actor),
    do: open(invocation, :critical, "mismatch", actor)

  defp ensure_critical(_needed, _live, _invocation, _actor), do: :ok

  defp ensure_warning(warnings, live, invocation, actor) do
    message = message(warnings)
    {keep, stale} = Enum.split_with(live, &(warnings != [] and &1.message == message))

    with :ok <- resolve_all(stale, actor) do
      if warnings == [] or keep != [],
        do: :ok,
        else: open(invocation, :warning, Enum.join(warnings, ","), actor)
    end
  end

  defp message([]), do: nil
  defp message(warnings), do: message_for(Enum.join(warnings, ","))

  defp message_for(reasons),
    do: "wire witness #{reasons}: model invocation needs operator review"

  defp open(invocation, severity, reasons, actor) do
    attrs = %{
      subject_resource: @subject,
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: severity,
      message: message_for(reasons),
      retryable: false
    }

    case Operations.open_failure(attrs, actor: actor) do
      {:ok, _failure} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_all(failures, actor) do
    Enum.reduce_while(failures, :ok, fn failure, :ok ->
      case Operations.resolve_failure(
             failure,
             %{resolution_note: "witness condition changed or cleared on reconciliation"},
             actor: actor
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp live_failures(invocation) do
    Failure
    |> Ash.Query.for_read(:attention, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and subject_resource == ^@subject and
        subject_id == ^invocation.id and class == :reconciliation_required
    )
    |> Ash.read()
  end

  ## Invocation answer (C1)

  @doc """
  The invocation-level witness status over its current links:
  `:unwitnessed` (none), `:mismatch` (any current mismatch), `:reconciled`
  (exactly one current reconciled primary and every other current link
  ancillary) or `:inferred`.
  """
  def status([]), do: :unwitnessed

  def status(links) do
    {primaries, others} = Enum.split_with(links, &(&1.evidence["classification"] == "primary"))

    cond do
      Enum.any?(links, &(&1.link_status == :mismatch)) ->
        :mismatch

      match?([%{link_status: :reconciled}], primaries) and
          Enum.all?(others, &(&1.evidence["classification"] == "ancillary")) ->
        :reconciled

      true ->
        :inferred
    end
  end

  ## Scheduling

  @doc """
  REC: enqueues reconciliation `generation` (default 1) of an invocation —
  an Oban job on the `reconciliation` queue and its `reconcile_model`
  Operation (key `reconcile_model:<id>:<generation>`) in one transaction.
  Idempotent: an existing Operation for the key is returned.
  """
  def enqueue(invocation_id, opts) do
    actor = Keyword.get(opts, :actor)
    generation = Keyword.get(opts, :generation, 1)
    meta = %{resource: Operation, action: :enqueue_reconcile_model, subject_id: invocation_id}

    # Through the guard, so a refused auditor mutation is audited (S2).
    Guard.run(meta, actor, fn ->
      with :ok <- authorize(actor),
           :ok <- valid_generation(generation),
           {:ok, invocation} <- reconcilable(invocation_id, actor) do
        do_enqueue(invocation.id, generation, actor)
      end
    end)
  end

  defp do_enqueue(invocation_id, generation, actor) do
    key = "reconcile_model:#{invocation_id}:#{generation}"

    with {:ok, nil} <- find_operation(key, actor),
         {:error, error} <- insert(invocation_id, generation, key, actor) do
      recover_race(key, actor, error)
    else
      {:ok, %Operation{} = operation} -> {:ok, operation}
      other -> other
    end
  end

  @doc "Maximum reconciliation generations per invocation (initial pass + re-drives)."
  def max_generations, do: @max_generations

  defp valid_generation(generation)
       when is_integer(generation) and generation in 1..@max_generations,
       do: :ok

  defp valid_generation(_generation), do: {:error, :invalid_generation}

  # Only a terminal ClaudeCLI invocation of the actor's tenant is scheduled.
  defp reconcilable(invocation_id, actor) when is_binary(invocation_id) do
    with {:ok, invocation} <- GuardedCall.get(ModelInvocation, invocation_id, actor: actor) do
      if eligible(invocation) == :ok, do: {:ok, invocation}, else: {:error, :not_reconcilable}
    end
  rescue
    _invalid_id -> {:error, :not_reconcilable}
  end

  defp reconcilable(_invocation_id, _actor), do: {:error, :not_reconcilable}

  # A concurrent enqueue won the (tenant, idempotency_key) identity; ours
  # rolled back with its job.
  defp recover_race(key, actor, error) do
    case find_operation(key, actor) do
      {:ok, %Operation{} = existing} -> {:ok, existing}
      _ -> {:error, error}
    end
  end

  defp insert(invocation_id, generation, key, actor) do
    Audit.transaction(fn ->
      args = %{
        "tenant_id" => actor.tenant_id,
        "model_invocation_id" => invocation_id,
        "generation" => generation
      }

      with {:ok, job} <- Oban.insert(ReconcileWorker.new(args)),
           {:ok, operation} <-
             Operations.create_operation(
               %{
                 kind: :reconcile_model,
                 queue: :reconciliation,
                 oban_job_id: job.id,
                 subject_resource: @subject,
                 subject_id: invocation_id,
                 idempotency_key: key,
                 correlation_id: invocation_id,
                 max_attempts: ReconcileWorker.max_attempts()
               },
               actor: actor
             ) do
        operation
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc "The reconcile_model Operations of an invocation, oldest first."
  def operations(invocation_id, actor) do
    Operation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(kind == :reconcile_model and subject_id == ^invocation_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read()
  end

  defp find_operation(key, actor) do
    Operation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(idempotency_key == ^key)
    |> Ash.read_one()
  end

  @doc "True when the invocation has a live warning attention condition."
  def live_warning?(invocation) do
    case live_failures(invocation) do
      {:ok, failures} -> Enum.any?(failures, &(&1.severity == :warning))
      _ -> false
    end
  end

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp decode_hex(nil), do: nil
  defp decode_hex(hex), do: Base.decode16!(hex, case: :lower)
end

defmodule SdrAgent.Agents.ResultGate do
  @moduledoc """
  The per-invocation result gate (R0-07 slice C; REQ-07-4; packet section
  2, "Commit and lock boundaries").

  `await/3` is step 2's wait: after a generation-2 ClaudeCLI call is
  validated and stored (step 1, committed), the gate reconciles **that**
  invocation in-process with `SdrAgent.Agents.Witness.reconcile/2` and its
  `gate:` option, as REC, polling until the outcome settles or the bound
  passes. It holds no lock and no transaction of its own while it waits:
  each reconcile commits its own short transaction, and `await/3` refuses
  to start inside an open transaction (`{:error, :in_transaction}`). An
  interrupted wait leaves nothing locked or half-written.

  The bound is `wait_ms/0` — 120 s, which configuration may only lower
  (`config :sdr_agent, SdrAgent.Agents.ResultGate, wait_ms:, poll_ms:`).

  Outcomes (the reconcile receipt `%{status, link_id, cause_id}`):

    * `{:ok, receipt}` once settled — reconciled, mismatch, an unconfigured
      or unreadable store, or any other final classification;
    * `{:timeout, receipt}` when the bound passes while the capture is
      still pending — no exchange yet, an open exchange or an incomplete
      capture;
    * `{:error, reason}` — e.g. `:invalid_gate`, `:in_transaction`.

  `finalize/4` is step 3, one transaction in the packet's lock order: the
  run `FOR UPDATE`, the run's Operation `FOR SHARE`, the invocation `FOR
  SHARE`, the receipt's primary link `FOR SHARE` (re-validated as
  current), the exact selected cause `FOR UPDATE` (live or resolved, chosen
  from the receipt or, for a gate-opened reason, the deduplicated existing
  gate cause), then the chain head. Under the head, with every dependent
  row already held, it opens a deduplicated gate cause when none was
  selected, decides the release inside `SdrAgent.Agents.ReleaseDecision.Prelocked`,
  and for a withheld outcome stops a running run with its exact receipt
  (`:witness_mismatch` or `:witness_unreconciled`). No row lock is
  requested after the head.

  Withheld reasons and typed classifications (rows G1, G2): a mismatch
  dominates (`:witness_mismatch`, reconcile's critical cause); an
  unconfigured or unreadable store after spend is `:store_unreadable`; a
  capture still pending at the bound is `:witness_timeout` (with its own
  gate cause); any other non-reconciled outcome is `:witness_missing` — no
  usable exact witness, not a claim that a file is absent. The
  classification is recorded only in the withheld event; a gate-opened
  cause's message names the reason only, so it deduplicates on
  (invocation, reason).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  @max_wait_ms 120_000
  @default_poll_ms 1_000
  # Observation warnings that mean the capture may still arrive.
  @pending ["witness_missing", "no_primary_exchange", "exchange_open", "capture_incomplete"]

  @doc "The effective wait bound: `min(config, 120_000)` ms; invalid config is ignored."
  @spec wait_ms() :: pos_integer()
  def wait_ms do
    case Keyword.get(config(), :wait_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_wait_ms)
      _ -> @max_wait_ms
    end
  end

  defp poll_ms do
    case Keyword.get(config(), :poll_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_poll_ms
    end
  end

  defp config, do: Application.get_env(:sdr_agent, __MODULE__, [])

  @doc """
  Waits, bounded and holding no lock, for the gate reconcile of
  `invocation` under `gate` (`%{run_id, operation_id}`). `opts` are passed
  to `Witness.reconcile/2` (`store_root:`, test-only `methods:`).
  """
  @spec await(struct(), map(), keyword()) ::
          {:ok, map()} | {:timeout, map()} | {:error, term()}
  def await(invocation, gate, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :in_transaction}
    else
      actor = Actor.system(:reconciler, invocation.tenant_id)

      opts =
        opts |> Keyword.take([:store_root, :methods]) |> Keyword.merge(actor: actor, gate: gate)

      deadline = System.monotonic_time(:millisecond) + wait_ms()
      poll(invocation.id, opts, deadline)
    end
  end

  defp poll(invocation_id, opts, deadline) do
    case Witness.reconcile(invocation_id, opts) do
      {:ok, %{receipt: receipt} = result} ->
        cond do
          not pending?(result) -> {:ok, receipt}
          expired?(deadline) -> {:timeout, receipt}
          true -> again(invocation_id, opts, deadline)
        end

      # The store changed under the observation: observe again.
      {:error, :stale_observation} ->
        if expired?(deadline),
          do: {:timeout, %{status: :unwitnessed, link_id: nil, cause_id: nil, codes: []}},
          else: again(invocation_id, opts, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp again(invocation_id, opts, deadline) do
    Process.sleep(min(poll_ms(), max(deadline - System.monotonic_time(:millisecond), 0)))
    poll(invocation_id, opts, deadline)
  end

  defp pending?(%{status: status, attention: attention}) when status in [:unwitnessed, :inferred],
    do: Enum.any?(attention, &(&1 in @pending))

  defp pending?(_result), do: false

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  ## Finalize (step 3)

  @unreadable_prefix "store_"
  @unsupported ~w(proxy_version_unsupported content_encoding_unsupported evidence_contract_invalid)
  @subject "SdrAgent.Agents.ModelInvocation"

  @doc """
  Finalizes the gate of `invocation` under `gate` for the `outcome` of
  `await/3` (`{:ok, receipt}` or `{:timeout, receipt}`). Returns
  `{:released, release, output}`, `{:withheld, release, run}` or
  `{:error, reason}` (nothing written).
  """
  @spec finalize(struct(), map(), {:ok | :timeout, map()}, keyword()) ::
          {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
  def finalize(invocation, gate, {kind, receipt}, _opts \\ []) when kind in [:ok, :timeout] do
    plan = plan(kind, receipt)
    actor = Actor.system(:agent_runtime, invocation.tenant_id)

    fn -> locked_finalize(invocation, gate, receipt, plan, actor) end
    |> Audit.transaction()
    |> case do
      {:ok, result} -> result
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  # The reason and typed classification of an outcome (rows G2, G5).
  def plan(:timeout, _receipt),
    do: %{release?: false, reason: :witness_timeout, classification: :capture_pending}

  def plan(:ok, %{status: :reconciled}), do: %{release?: true}

  def plan(:ok, %{status: :mismatch}),
    do: %{release?: false, reason: :witness_mismatch, classification: :mismatch}

  def plan(:ok, %{status: :skipped}),
    do: %{release?: false, reason: :store_unreadable, classification: :store_unconfigured}

  def plan(:ok, %{codes: codes}) do
    classification =
      cond do
        Enum.any?(codes, &String.starts_with?(&1, @unreadable_prefix)) -> :store_unreadable
        "multiple_primary_exchanges" in codes -> :ambiguous
        "unclassified_exchange" in codes -> :unclassified
        "method_not_enabled" in codes -> :method_not_enabled
        Enum.any?(codes, &(&1 in @unsupported)) -> :unsupported
        Enum.any?(codes, &(&1 in @pending)) -> :no_exchange
        true -> :inferred
      end

    reason = if classification == :store_unreadable, do: :store_unreadable, else: :witness_missing
    %{release?: false, reason: reason, classification: classification}
  end

  defp locked_finalize(invocation, gate, receipt, plan, actor) do
    tenant_id = invocation.tenant_id

    with {:ok, run} <- lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
         :ok <- own_run(run, invocation, gate),
         :ok <- lock_operation(run, tenant_id),
         {:ok, invocation} <- lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE"),
         {:ok, link} <- lock_link(receipt.link_id, invocation),
         {:ok, cause} <- select_cause(plan, receipt, invocation, run),
         {:ok, _head} <- Kernel.lock_head(tenant_id) do
      under_head(plan, invocation, run, link, cause, actor)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp own_run(%AgentRun{id: id, operation_id: operation_id}, invocation, gate) do
    if id == invocation.agent_run_id and operation_id == gate.operation_id,
      do: :ok,
      else: {:error, :invalid_gate}
  end

  defp lock_operation(%AgentRun{operation_id: nil}, _tenant_id), do: :ok

  defp lock_operation(%AgentRun{operation_id: id}, tenant_id) do
    with {:ok, _operation} <- lock(Operation, id, tenant_id, "FOR SHARE"), do: :ok
  end

  # The receipt's primary link, still current; otherwise none.
  defp lock_link(nil, _invocation), do: {:ok, nil}

  defp lock_link(id, invocation) do
    with {:ok, link} <- lock(WireWitnessLink, id, invocation.tenant_id, "FOR SHARE") do
      if link.model_invocation_id == invocation.id and current?(link),
        do: {:ok, link},
        else: {:ok, nil}
    end
  end

  defp current?(link) do
    superseded? =
      WireWitnessLink
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(link.tenant_id))
      |> Ash.Query.filter(supersedes_id == ^link.id)
      |> Ash.exists?()

    not superseded?
  end

  # The exact selected cause, locked FOR UPDATE before the head (live or
  # resolved): the receipt's for a mismatch or a reconcile-opened reason;
  # for a gate-opened reason (timeout), the deduplicated existing gate cause.
  defp select_cause(%{release?: true}, _receipt, _invocation, _run), do: {:ok, nil}

  defp select_cause(%{reason: :witness_mismatch}, receipt, invocation, run),
    do: mismatch_cause(receipt, invocation, run)

  defp select_cause(%{reason: :witness_timeout} = plan, _receipt, invocation, run),
    do: existing_gate_cause(plan.reason, invocation, run)

  defp select_cause(plan, receipt, invocation, run) do
    case usable(receipt.cause_id, invocation, run, :warning) do
      {:ok, cause} -> {:ok, cause}
      :none -> existing_gate_cause(plan.reason, invocation, run)
    end
  end

  # A known mismatch needs a usable critical cause (rows G5, R7-2).
  defp mismatch_cause(receipt, invocation, run) do
    case usable(receipt.cause_id, invocation, run, :critical) do
      {:ok, cause} -> {:ok, cause}
      :none -> {:error, :mismatch_cause_unbound}
    end
  end

  defp usable(nil, _invocation, _run, _severity), do: :none

  defp usable(id, invocation, run, severity) do
    case lock(Failure, id, invocation.tenant_id, "FOR UPDATE") do
      {:ok, %Failure{} = failure} ->
        if gate_capable?(failure, invocation, run) and failure.severity == severity,
          do: {:ok, failure},
          else: :none

      _ ->
        :none
    end
  end

  defp gate_capable?(failure, invocation, run) do
    failure.class == :reconciliation_required and failure.subject_resource == @subject and
      failure.subject_id == invocation.id and failure.operation_id == run.operation_id
  end

  defp existing_gate_cause(reason, invocation, run) do
    message = cause_message(reason)

    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and subject_resource == @subject and
        subject_id == ^invocation.id and class == :reconciliation_required and
        message == ^message and status in [:open, :acknowledged]
    )
    |> filter_operation(run.operation_id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read()
    |> case do
      {:ok, [cause | _]} -> {:ok, cause}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  defp filter_operation(query, nil), do: Ash.Query.filter(query, is_nil(operation_id))
  defp filter_operation(query, id), do: Ash.Query.filter(query, operation_id == ^id)

  defp cause_message(reason),
    do: "wire witness gate #{reason}: model invocation needs operator review"

  defp under_head(%{release?: true}, invocation, _run, link, nil, actor) do
    bindings = bindings(invocation, link, nil)

    Prelocked.run(bindings, fn prelocked ->
      attrs = %{
        model_invocation_id: invocation.id,
        disposition: :released,
        reason: :reconciled,
        wire_witness_link_id: link && link.id
      }

      with {:ok, release} <-
             Agents.decide_result_release(attrs, actor: actor, prelocked: prelocked),
           {:ok, output} <- ReleasedOutput.fetch(invocation.id, actor) do
        {:released, release, output}
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp under_head(plan, invocation, run, link, cause, actor) do
    case ensure_cause(cause, plan, invocation, run, actor) do
      {:ok, cause} ->
        Prelocked.run(
          bindings(invocation, link, cause),
          &withhold(&1, plan, invocation, run, link, cause, actor)
        )

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp withhold(prelocked, plan, invocation, run, link, cause, actor) do
    attrs = %{
      model_invocation_id: invocation.id,
      disposition: :withheld,
      reason: plan.reason,
      wire_witness_link_id: link && link.id,
      gate_cause_id: cause.id,
      gate_classification: plan.classification
    }

    with {:ok, release} <- Agents.decide_result_release(attrs, actor: actor, prelocked: prelocked),
         {:ok, run} <- stop(run, release, cause, plan, actor, prelocked) do
      {:withheld, release, run}
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  # Opened under the head: its FK targets (Operation, run) are already held.
  defp ensure_cause(%Failure{} = cause, _plan, _invocation, _run, _actor), do: {:ok, cause}

  defp ensure_cause(nil, plan, invocation, run, actor) do
    attrs = %{
      subject_resource: @subject,
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: if(plan.reason == :witness_mismatch, do: :critical, else: :warning),
      message: cause_message(plan.reason),
      retryable: false
    }

    attrs = if run.operation_id, do: Map.put(attrs, :operation_id, run.operation_id), else: attrs
    Operations.open_failure(attrs, actor: actor)
  end

  defp stop(%AgentRun{status: :running} = run, release, cause, plan, actor, prelocked) do
    attrs = %{
      status_reason: stop_reason(plan.reason),
      failure_reason: "model output withheld by the result gate: #{plan.reason}",
      witness_failure_id: cause.id,
      release_id: release.id
    }

    Agents.fail_run(run, attrs, actor: actor, prelocked: prelocked)
  end

  # A run no longer running (e.g. cancelled during the wait): the release
  # only; no stop.
  defp stop(run, _release, _cause, _plan, _actor, _prelocked), do: {:ok, run}

  defp stop_reason(:witness_mismatch), do: :witness_mismatch
  defp stop_reason(_reason), do: :witness_unreconciled

  defp bindings(invocation, link, cause),
    do: %{
      tenant_id: invocation.tenant_id,
      model_invocation_id: invocation.id,
      wire_witness_link_id: link && link.id,
      receipt_id: cause && cause.id
    }

  defp lock(resource, id, tenant_id, mode) when is_binary(id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(mode)
    |> Ash.read_one()
    |> case do
      {:ok, %^resource{} = row} -> {:ok, row}
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp lock(_resource, _id, _tenant_id, _mode), do: {:error, :not_found}
end

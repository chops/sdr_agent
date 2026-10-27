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

  C2* demo exception (S3 plan r2 §6, §6.1; ADR-0005 C2* items 5-7): with
  the selector naming a live entry, an inferred `:ok` outcome whose receipt
  names a link with only `method_not_enabled`/`cli_injected_context`, and an
  active snapshot (checked before the head, with no I/O), `finalize/4`
  takes the exception branch: every current link, the funding grant and
  allocation `FOR SHARE`, the head, then the `:demo_exception` decision
  under the registered context and the output only with present use
  authority. An under-head refusal rolls back with
  `{:demo_exception_refused, code}`, and `gate/3` repeats `finalize/4`
  exactly once with the exception disabled (`demo_exception: {:disabled,
  code}`); that repeat's refusal goes to Recovery. An existing demo row
  outside the branch rolls back `:demo_exception_exists` (Recovery honours
  it). While the selector is on, every withheld event records one closed
  `demo_exception_refusal` code; with it off nothing changes.
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.DemoException.Eligibility
  alias SdrAgent.Agents.Errors.DemoExceptionRefused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  # Slice B row B3 (accepted): the compiled gate mode, set by no config
  # file; anything but :enforced makes the gate inactive (refuse only).
  @mode Application.compile_env(:sdr_agent, [__MODULE__, :mode], :enforced)
  @max_wait_ms 120_000
  @default_poll_ms 1_000
  # Observation warnings that mean the capture may still arrive.
  @pending ["witness_missing", "no_primary_exchange", "exchange_open", "capture_incomplete"]

  @doc "The compiled result-gate mode (`:enforced` in every build; row B3)."
  @spec mode() :: atom()
  def mode, do: @mode

  @doc """
  Whether the result gate is active: true only for the compiled
  `:enforced` mode. Slice B's admission refuses every generation-2 real
  call while it is not (row B3); nothing can make an inactive gate active.
  """
  @spec active?() :: boolean()
  def active?, do: @mode == :enforced

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

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  # Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): a
  # `before_gate: fun/1` in this module's Application env runs on the
  # completed invocation before the gate step, so end-to-end worker tests
  # can stage a competing decision or a pre-existing cause. Compiled out of
  # every other build.
  if @test_seams do
    defp before_gate(invocation) do
      case Keyword.get(config(), :before_gate) do
        fun when is_function(fun, 1) ->
          fun.(invocation)
          :ok

        _none ->
          :ok
      end
    end
  else
    defp before_gate(_invocation), do: :ok
  end

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

  ## The gate (steps 2 and 3, with the G7 recovery)

  # Refusals that a fresh recovery attempt cannot change (row G7): a gate
  # that is not this invocation's, a nested call, and a known mismatch
  # without a usable critical cause (row R7-2: the owner's attention).
  @final [:invalid_gate, :in_transaction, :not_found, :mismatch_cause_unbound]

  @doc """
  The facade's gate step for a completed generation-2 ClaudeCLI
  `invocation` of the run named by `gate`: the bounded wait (`await/3`),
  then `finalize/4`; when finalization is refused, **one** recovery
  attempt in a fresh transaction (`SdrAgent.Agents.ResultGate.Recovery`,
  row G7). Returns `{:released, release, output}`, `{:withheld, release,
  run}`, or `{:error, reason}` — no business output, the run left
  recoverable by `SdrAgent.SDR.StaleRunSweeper`.

  C2* operation snapshot entry `:result_gate` (ADR-0005 C2* item 2): it
  inherits from the owning action, or owns when top-level.
  """
  @spec gate(struct(), map(), keyword()) ::
          {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
  def gate(invocation, gate, opts \\ []) do
    OperationSnapshot.enter(:result_gate, fn ->
      :ok = before_gate(invocation)

      with {kind, _receipt} = outcome when kind in [:ok, :timeout] <-
             await(invocation, gate, opts) do
        finalized(invocation, gate, outcome, opts)
      end
    end)
  end

  # Step 3, and one recovery attempt when finalization is refused (G7).
  defp finalized(invocation, gate, outcome, opts) do
    case finalize(invocation, gate, outcome, opts) do
      # C2* (AC6): exactly one repeat with the exception disabled, carrying
      # the code; its own refusal falls to the one Recovery below.
      {:error, {:demo_exception_refused, code}} ->
        opts = Keyword.put(opts, :demo_exception, {:disabled, code})
        invocation |> finalize(gate, outcome, opts) |> recover(invocation, gate, opts)

      result ->
        recover(result, invocation, gate, opts)
    end
  end

  defp recover({:error, reason}, _invocation, _gate, _opts) when reason in @final,
    do: {:error, reason}

  defp recover({:error, _refused}, invocation, gate, opts),
    do: __MODULE__.Recovery.run(invocation, gate, Keyword.delete(opts, :demo_exception))

  defp recover(result, _invocation, _gate, _opts), do: result

  @doc """
  Whether `run` holds an unreleased output: a completed generation-2
  ClaudeCLI invocation with no `:released` `ModelResultRelease` — none yet,
  or withheld (REQ-07-5/6; review MF5). The
  workers never turn such a run into a success or a `:crash`; it is left
  for the gate or for run recovery (`SdrAgent.SDR.StaleRunSweeper`). A read
  error counts as unreleased (fail closed).
  """
  @spec unreleased?(struct()) :: boolean()
  def unreleased?(%AgentRun{} = run) do
    case unreleased_invocations(run) do
      {:ok, invocations} -> invocations != []
      {:error, _error} -> true
    end
  end

  @doc """
  The run's completed generation-2 ClaudeCLI invocations with no `:released`
  release, in call order: undecided ones, and withheld ones whose run has
  not been stopped yet (review MF5). The callers ask only about running runs.
  """
  @spec unreleased_invocations(struct()) :: {:ok, [struct()]} | {:error, term()}
  def unreleased_invocations(%AgentRun{id: run_id, tenant_id: tenant_id}) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and agent_run_id == ^run_id and provider == :claude_cli and
        ledger_generation == 2 and status == :completed and
        not exists(result_release, disposition == :released)
    )
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.read()
  rescue
    error -> {:error, error}
  end

  ## Finalize (step 3)

  @unreadable_prefix "store_"
  @unsupported ~w(proxy_version_unsupported content_encoding_unsupported evidence_contract_invalid)
  @subject "SdrAgent.Agents.ModelInvocation"

  @doc """
  Finalizes the gate of `invocation` under `gate` for the `outcome` of
  `await/3` (`{:ok, receipt}` or `{:timeout, receipt}`), or for run
  recovery's own reconcile (`{:interrupted, receipt}`, row G5 R1: a
  mismatch stays `:witness_mismatch`, anything else is `:gate_interrupted`,
  never a release). Returns
  `{:released, release, output}`, `{:withheld, release, run}` or
  `{:error, reason}` (nothing written).
  """
  @spec finalize(struct(), map(), {:ok | :timeout, map()}, keyword()) ::
          {:released, struct(), term()} | {:withheld, struct(), struct()} | {:error, term()}
  def finalize(invocation, gate, {kind, receipt}, opts \\ [])
      when kind in [:ok, :timeout, :interrupted] do
    plan = plan(kind, receipt)
    actor = Actor.system(:agent_runtime, invocation.tenant_id)
    guard = Keyword.get(opts, :guard, fn _run -> :ok end)
    demo = Keyword.get(opts, :demo_exception)

    fn -> locked_finalize(invocation, gate, {kind, receipt}, {plan, guard, demo}, actor) end
    |> Audit.transaction()
    |> case do
      {:ok, result} ->
        result

      # A refused demo decide may roll the transaction back itself (Ash does
      # inside an open transaction), so the code is read here too.
      {:error, %Ash.Changeset{errors: errors}} ->
        {:error, errors |> Ash.Error.to_error_class() |> exception_error()}

      {:error, error} ->
        {:error, exception_error(error)}
    end
  end

  @doc false
  # The reason and typed classification of an outcome (rows G2, G5).
  def plan(:interrupted, %{status: :mismatch}), do: plan(:ok, %{status: :mismatch})

  def plan(:interrupted, _receipt),
    do: %{release?: false, reason: :gate_interrupted, classification: :interrupted}

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

  defp locked_finalize(invocation, gate, {kind, receipt}, {plan, guard, demo}, actor) do
    tenant_id = invocation.tenant_id

    with {:ok, run} <- lock(AgentRun, gate.run_id, tenant_id, "FOR UPDATE"),
         :ok <- own_run(run, invocation, gate),
         :ok <- lock_operation(run, tenant_id),
         :ok <- guard.(run),
         {:ok, invocation} <- lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE") do
      existing = existing_disposition(invocation)

      cond do
        exception_branch?(kind, receipt, demo) ->
          exception(invocation, receipt, actor)

        # §6.1: a demo row is honoured by Recovery, never re-decided here.
        existing == :demo_exception ->
          Repo.rollback(:demo_exception_exists)

        true ->
          ordinary(invocation, run, {kind, receipt}, {plan, demo}, actor)
      end
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp ordinary(invocation, run, {kind, receipt}, {plan, demo}, actor) do
    with {:ok, link} <- lock_link(receipt.link_id, invocation),
         {:ok, cause} <- select_cause(plan, receipt, invocation, run),
         {:ok, _head} <- Kernel.lock_head(invocation.tenant_id) do
      plan = refusal(plan, invocation, {kind, receipt}, demo)
      under_head(plan, invocation, run, link, cause, actor)
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  ## C2* demo exception (S3 plan r2 §6; ADR-0005 C2* items 5-7)

  @exception_codes MapSet.new(["method_not_enabled", "cli_injected_context"])

  # Pre-head branch selection, with no I/O: the selector names a live entry,
  # this is not the disabled repeat, the outcome is an inferred `:ok` naming
  # a link with only the expected reason codes, and (last) the process has
  # an active snapshot.
  defp exception_branch?(kind, receipt, demo) do
    DemoException.selected?() and not DemoException.inert?() and is_nil(demo) and
      kind == :ok and receipt.status == :inferred and is_binary(receipt.link_id) and
      "method_not_enabled" in receipt.codes and
      MapSet.subset?(MapSet.new(receipt.codes), @exception_codes) and
      DemoException.attestation() != :none
  end

  # Every current link sorted by id, the funding grant, then the allocation
  # `FOR SHARE`, then the head; under the head no row lock is requested.
  # The decision (new or replay) is `ReleaseDecision`'s under the registered
  # context, which captures the instant; output only with use authority.
  defp exception(invocation, receipt, actor) do
    with {:ok, links} <- lock_current_links(invocation),
         :ok <- Admission.lock_charge(invocation),
         {:ok, _head} <- Kernel.lock_head(invocation.tenant_id) do
      generation =
        case DemoException.attestation() do
          {:ok, %{generation: generation}} -> generation
          _none -> nil
        end

      bindings = %{
        tenant_id: invocation.tenant_id,
        model_invocation_id: invocation.id,
        wire_witness_link_id: receipt.link_id,
        receipt_id: nil,
        finalizer: :result_gate,
        current_link_ids: Enum.map(links, & &1.id),
        grant_id: invocation.grant_id,
        allocation_id: invocation.allocation_id,
        snapshot_generation: generation
      }

      Prelocked.run(bindings, &decide_exception(&1, invocation, receipt, actor))
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp decide_exception(prelocked, invocation, receipt, actor) do
    attrs = %{
      model_invocation_id: invocation.id,
      disposition: :demo_exception,
      reason: :v4_uncalibrated,
      wire_witness_link_id: receipt.link_id
    }

    with {:ok, release} <- Agents.decide_result_release(attrs, actor: actor, prelocked: prelocked),
         {:ok, output} <- ReleasedOutput.fetch(invocation.id, actor) do
      {:released, release, output}
    else
      {:error, error} -> Repo.rollback(exception_error(error))
    end
  end

  # A refused decide comes back as its changeset or as the error class.
  defp exception_error(%{errors: errors} = error) when is_list(errors) do
    case Enum.find(errors, &match?(%DemoExceptionRefused{}, &1)) do
      %DemoExceptionRefused{code: code} -> {:demo_exception_refused, code}
      nil -> error
    end
  end

  defp exception_error(error), do: error

  # While the selector is on, a withheld outcome records one closed code:
  # the code the disabled repeat carries, or the first failing one evaluated
  # here under the head with plain reads (Recovery's own outcomes record
  # `exception_off`, `withhold/7`).
  defp refusal(%{release?: false} = plan, invocation, {kind, receipt}, demo) do
    if DemoException.selected?() do
      code =
        case demo do
          {:disabled, code} -> code
          nil -> evaluated_code(invocation, kind, receipt)
        end

      Map.put(plan, :demo_exception_refusal, code)
    else
      plan
    end
  end

  defp refusal(plan, _invocation, _outcome, _demo), do: plan

  defp evaluated_code(invocation, kind, receipt) do
    facts =
      invocation
      |> Eligibility.load(receipt.link_id)
      |> Map.merge(%{receipt: receipt, kind: kind})

    case Eligibility.evaluate(facts, Clock.utc_now()) do
      {:refused, code} -> code
      {:ok, _authority} -> :exception_off
    end
  end

  defp existing_disposition(invocation) do
    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
    )
    |> Ash.read_one()
    |> case do
      {:ok, %ModelResultRelease{disposition: disposition}} -> disposition
      _none -> nil
    end
  end

  @doc false
  # Every current link of `invocation`, sorted by id, `FOR SHARE` (shared
  # with `SdrAgent.Agents.ResultGate.Recovery`).
  def lock_current_links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id and
        not exists(successors, true)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read()
  end

  @doc false
  def own_run(%AgentRun{id: id, operation_id: operation_id}, invocation, gate) do
    if id == invocation.agent_run_id and operation_id == gate.operation_id,
      do: :ok,
      else: {:error, :invalid_gate}
  end

  @doc false
  def lock_operation(%AgentRun{operation_id: nil}, _tenant_id), do: :ok

  def lock_operation(%AgentRun{operation_id: id}, tenant_id) do
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

  @doc false
  def gate_capable?(failure, invocation, run) do
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

  @doc false
  # Under the head, every dependent row held: the release (and, withheld,
  # the cause and the run stop) inside Prelocked.
  def under_head(%{release?: true}, invocation, _run, link, nil, actor) do
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

  def under_head(plan, invocation, run, link, cause, actor) do
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
    attrs =
      %{
        model_invocation_id: invocation.id,
        disposition: :withheld,
        reason: plan.reason,
        wire_witness_link_id: link && link.id,
        gate_cause_id: cause.id,
        gate_classification: plan.classification
      }
      |> with_refusal(plan)

    with {:ok, release} <- Agents.decide_result_release(attrs, actor: actor, prelocked: prelocked),
         {:ok, run} <- stop(run, release, cause, plan, actor, prelocked) do
      {:withheld, release, run}
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  # C2* (ADR-0005 item 5; OQ7): while the selector is on, one closed code;
  # an outcome with none computed (run recovery's) records `exception_off`.
  defp with_refusal(attrs, plan) do
    if DemoException.selected?(),
      do:
        Map.put(
          attrs,
          :demo_exception_refusal,
          Map.get(plan, :demo_exception_refusal, :exception_off)
        ),
      else: attrs
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

  @doc false
  # Review MF5: stops a still-running run on an existing withheld release's
  # original bound cause, under Prelocked (the cause, and the release's
  # link, already locked before the head by the caller).
  def stop_on_release(run, release, invocation, link, cause, actor) do
    Prelocked.run(bindings(invocation, link, cause), fn prelocked ->
      case stop(run, release, cause, %{reason: release.reason}, actor, prelocked) do
        {:ok, stopped} -> {:withheld, release, stopped}
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp stop_reason(:witness_mismatch), do: :witness_mismatch
  defp stop_reason(_reason), do: :witness_unreconciled

  defp bindings(invocation, link, cause),
    do: %{
      tenant_id: invocation.tenant_id,
      model_invocation_id: invocation.id,
      wire_witness_link_id: link && link.id,
      receipt_id: cause && cause.id
    }

  @doc false
  def lock(resource, id, tenant_id, mode) when is_binary(id) do
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

  def lock(_resource, _id, _tenant_id, _mode), do: {:error, :not_found}
end

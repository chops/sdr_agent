defmodule SdrAgent.SDR.StaleRunSweeper do
  @moduledoc """
  Oban cron worker (queue `default`, every 5 minutes): recovers AgentRuns
  abandoned by a crash the worker could not record (S7 choice 11/15, S9b
  review item 3) — a VM crash, a killed process, or a crash of the
  terminal write itself — which leave the run (and its Operation)
  `running` and a model call `sent`.

  A run is *abandoned* when it has been `running` for longer than
  `stale_after_seconds/0` (default 1800 s; `config :sdr_agent,
  SdrAgent.SDR.StaleRunSweeper, stale_after_seconds:`) **and** its Oban job
  is no longer live (not `available`, `scheduled`, `executing` or
  `retryable` — after a restart Oban's lifeline discards an orphaned
  one-attempt agent job — or gone). A run whose job is still live is never
  touched.

  Recovery, per run, in one transaction, as the agent runtime through
  existing actions only. The run, its Operation, its Oban job row and all
  its `sent` invocations are locked `FOR UPDATE` before the first append
  (ADR-0009), and the run's staleness and the job's liveness are decided
  again under those locks (the first, unlocked observation is only a
  prefilter; a job made live meanwhile is left alone, review #25). A lookup
  error is never read as a missing job: the run is skipped.

    1. every `sent` ModelInvocation of the run → `unknown` (never re-sent;
       it still counts against the budgets), and every `reserved` one →
       `failed` with `sent_at` nil (C9-03: never launched — a launch is
       sent before any process starts and needs this run lock and a
       running run — so never unknown; its charged attempt is kept and no
       use is settled); both are locked in one statement, in sequence
       order;
    2. the run → `failed` with `status_reason: :crash` and a redacted
       `failure_reason` naming the job state; this opens the run's
       attention Failure (operator retry: `SDR.retry_run/2`, S13b);
    3. a `running` Operation → `failed` linking that Failure (discarded at
       its one attempt).

  **Result gate (R0-07 slice C, row G5; REQ-07-6).** An abandoned run that
  holds a completed generation-2 ClaudeCLI invocation with no
  `ModelResultRelease` is not a crash: its output stays withheld, no model
  is called, and one selection rule applies (`SdrAgent.Agents.ResultGate`):

    * R1, nothing persisted for the invocation (no link, no
      `reconciliation_required` Failure on it, no release): the gated
      `Witness.reconcile/2` (observation outside every lock), then
      finalization with `:gate_interrupted` — `:witness_mismatch` with its
      critical cause for a known mismatch;
    * R2, links or a cause exist: no reconcile; `ResultGate.Recovery`
      selects from the durable state;
    * a refused finalization gets one recovery attempt; an existing
      release is authoritative.

  In prototype runtime an unreleased invocation is always reconciled and
  finalized by the prototype gate, a refused finalization is returned (an
  exhausted recheck is retried by the next pass), and Recovery decides
  nothing new (D-237 TF-1).

  The run's staleness and its job's liveness are decided again under
  finalization's own locks (run, Operation, job). The run stops
  `:witness_mismatch` or `:witness_unreconciled` on its gate cause, and
  its Operation then fails by the worker's rule
  (`SdrAgent.SDR.AgentWorker.fail_operation/3`). A known mismatch without
  a usable critical cause (`:mismatch_cause_unbound`) is skipped: it stays
  the owner's attention.

  **R3, a terminal run** with such an invocation completed before the stale
  cutoff gets the same selection and a withheld release only; the run and
  its Operation are not changed.

  **A gate stop's Operation (review MF1).** The gate stop and the
  Operation's failure are separate transactions (packet step 4), so a run
  stopped `:witness_mismatch` or `:witness_unreconciled` whose Operation is
  still `running` and whose job is no longer live has its Operation failed
  here, revalidated under the run, Operation and job locks, by the worker's
  rule (`SdrAgent.SDR.AgentWorker.fail_operation/3`). C2-02b1: a run
  stopped `:model_not_admitted` (by its worker, or by a profile switch
  drain whose Operation transaction never ran) is healed the same way,
  under the same locks and the same dead-job guard. No other terminal run's
  Operation is touched.

  Idempotent: a recovered run is `failed`, so a later sweep skips it.
  Integration-queue reply runs have no Operation (S9 choice 12); their job is
  found by its `run_id` argument.

  **Reservations of terminal runs (C9-03, case (b); R0 readiness packet,
  entity PASS 2026-10-12).** Then, per terminal run (`succeeded`, `failed`,
  `budget_exhausted`, `cancelled`) that has a `reserved` ModelInvocation
  reserved strictly before the stale cutoff (`reserved_at < now −
  stale_after_seconds/0`, a grace period for a live caller to settle it
  itself), one transaction: the run `FOR UPDATE` (its terminal status
  re-read), then those invocations `FOR UPDATE` in sequence order (status
  and age re-read), each → `failed` with `sent_at` nil. The locked terminal
  run plus the locked `reserved` state is the proof that it never launched
  and never will (launch admission refuses a non-running run). The run, its
  cause and its Operation are not written; no Failure is opened; the
  attempt stays charged. Selection is by the `reserved` state, so a later
  pass still finds a row that has since aged past the cutoff, and a failed
  row is never touched again. Queued and running runs are never in this
  case.

  **`sent` rows of terminal runs (L2 E1, case (c); `docs/product/r0/
  l2-enablement.md`).** Last, per terminal run that is not `:proof` (a
  pre-R0 NULL origin included) with a `sent` ModelInvocation sent strictly
  before the cutoff, `SdrAgent.Agents.mark_terminal_run_sent_unknown/3`
  marks those rows `unknown` (one transaction, run first; see there). A
  ledger-only normalization: the run is not settled or written, its
  counters are not backfilled, the attempt stays charged, and no Failure,
  Operation, release or retry follows. It is not cleanup proof and not
  retry permission. A run whose invocations record calibration authority,
  or whose reservation evidence cannot be bound, is left unchanged.

  **The grace setting.** Each sweep reads `stale_after_seconds` once: the
  configuration must be a keyword list and the value a positive integer.
  Otherwise the sweep writes nothing, logs the fixed warning
  `stale_run_sweeper.invalid_stale_after` (no value) and returns `:ok`.
  """
  use Oban.Worker, queue: :default, max_attempts: 1
  use SdrAgent.Workers.ErrorBoundary

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo
  alias SdrAgent.SDR.AgentWorker

  @live_states ~w(available scheduled executing retryable)
  @terminal [:succeeded, :failed, :budget_exhausted, :cancelled]
  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @impl Oban.Worker
  def perform(_job) do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> sweep(tenant_id)
      {:error, _not_bootstrapped} -> :ok
    end
  end

  @doc "Seconds a run may be `running` before it can be judged abandoned."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds do
    :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:stale_after_seconds, 1800)
  end

  @doc "Recovers the tenant's abandoned runs (see the moduledoc). Returns `:ok`."
  @spec sweep(String.t()) :: :ok | {:error, term()}
  def sweep(tenant_id) do
    case stale_after() do
      {:ok, seconds} ->
        sweep(tenant_id, seconds)

      :error ->
        Logger.warning("stale_run_sweeper.invalid_stale_after")
        :ok
    end
  end

  # L2 E1: the configured grace, read once per sweep: the config a keyword
  # list and the value a positive integer, else :error (nothing is swept).
  defp stale_after do
    config = Application.get_env(:sdr_agent, __MODULE__, [])

    with true <- Keyword.keyword?(config),
         seconds when is_integer(seconds) and seconds > 0 <-
           Keyword.get(config, :stale_after_seconds, 1800) do
      {:ok, seconds}
    else
      _invalid -> :error
    end
  end

  defp sweep(tenant_id, seconds) do
    actor = Actor.system(:agent_runtime, tenant_id)
    cutoff = DateTime.add(Clock.utc_now(), -seconds, :second)

    with {:ok, runs} <- Agents.list_runs(actor: actor),
         :ok <-
           runs
           |> Enum.filter(
             &(&1.status == :running and stale?(&1, cutoff) and maybe_abandoned?(&1, actor))
           )
           |> each_ok(&recovered(recover_owned(&1, cutoff, actor))),
         {:ok, invocations} <- terminal_unreleased(cutoff, actor),
         :ok <- each_ok(invocations, &recovered(recover_terminal(&1, actor))),
         {:ok, stopped} <- Agents.list_runs(actor: actor),
         :ok <- stopped |> Enum.filter(&gate_stopped?/1) |> each_ok(&recovered(heal(&1, actor))),
         {:ok, run_ids} <- old_reservation_runs(cutoff, actor),
         :ok <- each_ok(run_ids, &recovered(recover_stopped(&1, cutoff, actor))),
         {:ok, sent_runs} <- terminal_sent_runs(cutoff, actor) do
      each_ok(sent_runs, fn run_id ->
        recovered(Agents.mark_terminal_run_sent_unknown(run_id, seconds, actor: actor))
      end)
    end
  end

  # Case (c) prefilter (unlocked; grants nothing): runs with a `sent` row
  # older than the cutoff whose run is terminal and not proof (NULL origin
  # included); the domain function decides again under its locks.
  defp terminal_sent_runs(cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and status == :sent and sent_at < ^cutoff and
        exists(
          agent_run,
          status in ^@terminal and (is_nil(usage_origin) or usage_origin != :proof)
        )
    )
    |> Ash.Query.select([:agent_run_id])
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, rows |> Enum.map(& &1.agent_run_id) |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  # Review MF1: a run the result gate stopped whose Operation is still
  # running (the worker or sweeper died between the gate's commit and the
  # Operation's own transaction, packet step 4). C2-02b1: likewise a run
  # stopped :model_not_admitted (by its worker or by a profile switch
  # drain) whose Operation's transaction never ran.
  defp gate_stopped?(run),
    do:
      run.status == :failed and
        run.status_reason in [:witness_mismatch, :witness_unreconciled, :model_not_admitted] and
        is_binary(run.operation_id)

  # One transaction: the run (re-read), its Operation and its job are locked
  # in the recovery order and revalidated — still a gate stop, the
  # Operation still running, the job no longer live — then the Operation
  # fails by the worker's rule (the live gate cause, or its own Failure
  # naming a resolved one). Anything else is left alone.
  defp heal(run, actor) do
    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run.id, actor),
           true <- gate_stopped?(run) || {:error, :not_running},
           {:ok, %{status: :running} = operation} <- lock_operation(run, actor),
           {:ok, state} <- job_state(run, actor, :for_update),
           :ok <- not_live(state) do
        :ok = AgentWorker.fail_operation(operation, run, actor)
        run
      else
        {:ok, _settled_operation} -> Repo.rollback(:not_running)
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # Skips: the run stopped, became fresh, or its job is live under the lock
  # (case (b): the run is not terminal under its lock).
  # A known mismatch without a usable critical cause stays the owner's
  # attention (row R7-2); a later pass completes once it is resolved.
  # A withheld release without a readable bound cause is left as it is
  # (fail closed; review MF5). A release that races recovery is honoured
  # by recovery itself (G7, review round 2).
  defp recovered({:error, skip})
       when skip in [
              :not_running,
              :job_live,
              :not_terminal,
              :proof_run,
              :calibration_authority,
              :authority_unbindable,
              :run_not_found,
              :mismatch_cause_unbound,
              :binding_unavailable
            ],
       do: :ok

  # A stale observation is retried by the next pass.
  defp recovered({:error, :stale_observation}), do: :ok

  if @prototype_compiled do
    # D-237 TF-1 OD-2 (Codex cc688175): in PROTOTYPE runtime only, an
    # exhausted recheck is retried on the next pass; ordinary runtime
    # returns the original error, as today.
    defp recovered({:error, :recheck_failed} = refused) do
      if SdrAgent.Prototype.runtime() == :prototype, do: :ok, else: refused
    end
  end

  defp recovered({:ok, _}), do: :ok
  defp recovered(error), do: error

  # Applies `fun` (returning :ok | {:error, _}) to each item; stops at the first error.
  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stale?(%{started_at: %DateTime{} = started}, cutoff),
    do: DateTime.compare(started, cutoff) == :lt

  defp stale?(_run, _cutoff), do: false

  # Unlocked prefilter only (saves a transaction per live run); recovery
  # decides again under its locks. A lookup error is not a missing job: the
  # run is skipped.
  defp maybe_abandoned?(run, actor) do
    case job_state(run, actor, nil) do
      {:ok, state} -> state not in @live_states
      {:error, _} -> false
    end
  end

  # Assignment runs: the job of their Operation (`oban_job_id`). Reply runs
  # (no Operation): the ReplyWorker jobs naming the run. `{:ok, "missing"}`
  # only when the bound job row is gone; with `lock`, the rows are locked.
  defp job_state(%{operation_id: operation_id}, actor, lock) when is_binary(operation_id) do
    case Operations.get_operation(operation_id, actor: actor) do
      {:ok, %{oban_job_id: job_id}} when is_integer(job_id) ->
        from(j in Oban.Job, where: j.id == ^job_id, select: j.state)
        |> locking(lock)
        |> Repo.all()
        |> states()

      {:ok, _unbound} ->
        {:error, :job_unbound}

      error ->
        error
    end
  end

  defp job_state(%{id: run_id}, _actor, lock) do
    from(j in Oban.Job,
      where:
        j.worker == "SdrAgent.SDR.ReplyWorker" and
          fragment("?->>'run_id' = ?", j.args, ^run_id),
      order_by: [asc: j.id],
      select: j.state
    )
    |> locking(lock)
    |> Repo.all()
    |> states()
  end

  defp locking(query, nil), do: query
  defp locking(query, :for_update), do: from(j in query, lock: "FOR UPDATE")

  defp states([]), do: {:ok, "missing"}

  defp states(states),
    do: {:ok, Enum.find(states, List.last(states), &(&1 in @live_states))}

  # C2* operation snapshot entry `:stale_run_recover` (ADR-0005 C2* addendum
  # 1, D-227): each per-run recovery is one operation, sampled before its
  # unlocked prefilter; the locked re-check, the :gate_owned retry and any
  # Recovery it runs inherit that snapshot.
  defp recover_owned(run, cutoff, actor),
    do: OperationSnapshot.enter(:stale_run_recover, fn -> recover(run, cutoff, actor) end)

  # R0-07 slice C: a run holding an unreleased output is recovered through
  # the result gate (G5), never as a crash.
  # The unlocked choice is a prefilter only: the crash path decides again
  # under its run lock (review MF2) and, when a gated output has appeared,
  # rolls back before any append; the gate path then runs outside every lock
  # (its observation needs none).
  defp recover(run, cutoff, actor) do
    case ResultGate.unreleased_invocations(run) do
      {:ok, []} ->
        case recover_crash(run, cutoff, actor) do
          {:error, :gate_owned} -> recover(run, cutoff, actor)
          result -> result
        end

      {:ok, [invocation | _]} ->
        recover_gate(run, invocation, cutoff, actor)

      {:error, error} ->
        {:error, error}
    end
  end

  # One transaction; every row it writes is locked before the first append
  # (ADR-0009): run → Operation → job → all `sent` and `reserved`
  # invocations. Staleness
  # and job liveness are decided again under those locks; Oban's own job
  # transitions (lifeline, staging, `retry_job`) wait on the job row lock.
  defp recover_crash(run, cutoff, actor) do
    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run.id, actor),
           :ok <- abandoned(run, cutoff),
           :ok <- no_gated_output(run),
           {:ok, operation} <- lock_operation(run, actor),
           {:ok, state} <- job_state(run, actor, :for_update),
           :ok <- not_live(state),
           {:ok, invocations} <- lock_unsettled_invocations(run, actor),
           :ok <- each_ok(invocations, &recover_invocation(&1, "run_abandoned", actor)),
           {:ok, failed} <-
             Agents.fail_run(
               run,
               %{
                 status_reason: :crash,
                 failure_reason:
                   "abandoned: the worker exited without recording an outcome (job #{state})"
               },
               actor: actor
             ),
           {:ok, _} <- fail_operation(operation, failed, actor) do
        failed
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # Rows G5 R1/R2: the gate's finalization (its own locks: run, Operation,
  # then — in this guard — the job, before the invocation and the head),
  # then the Operation by the worker's rule in its own transaction.
  defp recover_gate(run, invocation, cutoff, actor) do
    guard = fn locked ->
      with :ok <- abandoned(locked, cutoff),
           {:ok, state} <- job_state(locked, actor, :for_update),
           do: not_live(state)
    end

    case gate_recovery(invocation, run, guard) do
      {:withheld, _release, %{status: :failed} = stopped} -> fail_gate_operation(stopped, actor)
      {:withheld, _release, stopped} -> {:ok, stopped}
      {:released, _release, _output} -> {:error, :not_running}
      {:error, error} -> {:error, error}
    end
  end

  defp fail_gate_operation(%{operation_id: nil} = stopped, _actor), do: {:ok, stopped}

  defp fail_gate_operation(stopped, actor) do
    case Operations.get_operation(stopped.operation_id, actor: actor) do
      {:ok, %{status: :running} = operation} ->
        :ok = AgentWorker.fail_operation(operation, stopped, actor)
        {:ok, stopped}

      {:ok, _settled} ->
        {:ok, stopped}

      error ->
        error
    end
  end

  # Row G5 R3: a withheld release only (finalization stops no terminal run).
  defp recover_terminal(invocation, actor) do
    with {:ok, run} <- Agents.get_run(invocation.agent_run_id, actor: actor) do
      guard = fn locked -> terminal(locked) end

      case gate_recovery(invocation, run, guard) do
        {:error, error} -> {:error, error}
        _decided -> {:ok, run}
      end
    end
  end

  # R1 (nothing persisted): the gated reconcile, then finalization with
  # :gate_interrupted. R2: the recovery selection. One recovery attempt
  # after a refused finalization (G7).
  defp gate_recovery(invocation, run, guard) do
    gate = %{run_id: run.id, operation_id: run.operation_id}

    if reconcile_first?(invocation) do
      rec = Actor.system(:reconciler, invocation.tenant_id)

      case reconcile(invocation, rec, gate) do
        {:ok, %{receipt: receipt}} -> finalize(invocation, gate, receipt, guard)
        {:ok, _no_receipt} -> Recovery.run(invocation, gate, guard: guard)
        {:error, error} -> {:error, error}
      end
    else
      Recovery.run(invocation, gate, guard: guard)
    end
  end

  if @prototype_compiled do
    # D-237 TF-1 (Codex eff38bd0): in prototype runtime an unreleased
    # invocation is always finalized by the prototype gate (reconcile first,
    # then {:interrupted, receipt}); an existing release goes to Recovery.
    defp reconcile_first?(invocation) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: not released?(invocation),
        else: nothing_persisted?(invocation)
    end

    # An unlocked routing prefilter only: the locked finalize decides again.
    # `Ash.exists?/2` raises on a read error; nothing reads it as false.
    defp released?(invocation),
      do: routing_read(invocation, fn -> release_exists?(invocation) end)

    defp release_exists?(invocation) do
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(model_invocation_id == ^invocation.id)
      |> Ash.exists?()
    end
  else
    defp reconcile_first?(invocation), do: nothing_persisted?(invocation)
  end

  # D-237 TF-1 RED seams (plan r3 SW-6; Codex 5ec3911b). Test-seam builds
  # with the prototype authority only, consulted in prototype runtime only.
  # `released_read: fun/1` replaces the routing read with a boolean (a raise
  # or a throw of the fun propagates unchanged); `reconcile_result: fun/1`
  # injects `{:error, _}` in place of the gated reconcile, or `:passthrough`
  # (the real reconcile). Any other value raises a fixed, value-free
  # ArgumentError, so no receipt, release or success can be manufactured.
  # Every other build, and the ordinary runtime, has no callback path.
  if @prototype_compiled do
    if @test_seams do
      # Reached only from `released?/1`, which only the prototype-runtime
      # branch of `reconcile_first?/1` calls.
      defp routing_read(invocation, real) do
        case Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :released_read) do
          fun when is_function(fun, 1) ->
            case fun.(invocation) do
              routed when is_boolean(routed) -> routed
              _other -> raise ArgumentError, "released_read returns a boolean only"
            end

          _none ->
            real.()
        end
      end
    else
      defp routing_read(_invocation, real), do: real.()
    end
  end

  # `@test_seams` first: the production build reads it here (WAE).
  if @test_seams and @prototype_compiled do
    defp reconcile(invocation, rec, gate) do
      real = fn -> Witness.reconcile(invocation.id, actor: rec, gate: gate) end
      hook = Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :reconcile_result)

      if SdrAgent.Prototype.runtime() == :prototype and is_function(hook, 1) do
        case hook.(invocation) do
          {:error, _error} = injected -> injected
          :passthrough -> real.()
          _other -> raise ArgumentError, "reconcile_result injects {:error, _} only"
        end
      else
        real.()
      end
    end
  else
    defp reconcile(invocation, rec, gate),
      do: Witness.reconcile(invocation.id, actor: rec, gate: gate)
  end

  @final [:not_running, :job_live, :not_terminal, :job_unbound, :mismatch_cause_unbound]

  defp finalize(invocation, gate, receipt, guard) do
    case ResultGate.finalize(invocation, gate, {:interrupted, receipt}, guard: guard) do
      {:error, reason} when reason in @final -> {:error, reason}
      {:error, _refused} = refused -> after_refused(refused, invocation, gate, guard)
      decided -> decided
    end
  end

  if @prototype_compiled do
    defp after_refused(refused, invocation, gate, guard) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: refused,
        else: Recovery.run(invocation, gate, guard: guard)
    end
  else
    defp after_refused(_refused, invocation, gate, guard),
      do: Recovery.run(invocation, gate, guard: guard)
  end

  # No link, no reconciliation_required Failure on it (live or resolved),
  # no release (a withheld one goes to recovery, review MF5).
  defp nothing_persisted?(invocation) do
    opts = Kernel.opts(invocation.tenant_id)

    released? =
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(model_invocation_id == ^invocation.id)
      |> Ash.exists?()

    links? =
      WireWitnessLink
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(model_invocation_id == ^invocation.id)
      |> Ash.exists?()

    causes? =
      Failure
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(
        subject_resource == "SdrAgent.Agents.ModelInvocation" and subject_id == ^invocation.id and
          class == :reconciliation_required
      )
      |> Ash.exists?()

    not released? and not links? and not causes?
  end

  # R3 prefilter (unlocked): completed generation-2 invocations with no
  # release, of terminal runs, completed before the cutoff (a grace period
  # for a live gate to decide itself); recovery decides under its locks.
  defp terminal_unreleased(cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and provider == :claude_cli and ledger_generation == 2 and
        status == :completed and updated_at < ^cutoff and not exists(result_release, true) and
        exists(agent_run, status in ^@terminal)
    )
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.read()
  end

  # Under the run lock (a settlement completes its invocation while holding
  # it): a completed generation-2 output with no release is the gate's.
  defp no_gated_output(run) do
    case ResultGate.unreleased_invocations(run) do
      {:ok, []} -> :ok
      {:ok, _gated} -> {:error, :gate_owned}
      error -> error
    end
  end

  defp abandoned(%{status: :running} = run, cutoff),
    do: if(stale?(run, cutoff), do: :ok, else: {:error, :not_running})

  defp abandoned(_run, _cutoff), do: {:error, :not_running}

  defp not_live(state) when state in @live_states, do: {:error, :job_live}
  defp not_live(_state), do: :ok

  defp lock(resource, id, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_running}
      other -> other
    end
  end

  defp lock_operation(%{operation_id: nil}, _actor), do: {:ok, nil}
  defp lock_operation(%{operation_id: id}, actor), do: lock(Operation, id, actor)

  # The run's `sent` and `reserved` invocations, in one statement, in
  # sequence order.
  defp lock_unsettled_invocations(run, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(agent_run_id == ^run.id and status in [:sent, :reserved])
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read()
  end

  defp recover_invocation(%{status: :sent} = invocation, _reason, actor) do
    case Agents.mark_model_invocation_unknown(invocation, actor: actor) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Never launched (C9-03): failed, never unknown; nothing is settled.
  defp recover_invocation(%{status: :reserved} = invocation, reason, actor) do
    attrs = %{error: %{"kind" => "abandoned_before_launch", "reason" => reason}}

    case Agents.fail_model_invocation(invocation, attrs, actor: actor) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Case (b) prefilter (unlocked): runs with a reservation older than the
  # cutoff; recovery decides again under its locks.
  defp old_reservation_runs(cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and status == :reserved and reserved_at < ^cutoff
    )
    |> Ash.Query.select([:agent_run_id])
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, rows |> Enum.map(& &1.agent_run_id) |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  # Case (b): run → its old reserved invocations → appends (ADR-0009).
  defp recover_stopped(run_id, cutoff, actor) do
    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run_id, actor),
           :ok <- terminal(run),
           {:ok, invocations} <- lock_old_reservations(run, cutoff, actor),
           :ok <- each_ok(invocations, &recover_invocation(&1, "run_stopped", actor)) do
        length(invocations)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp terminal(%{status: status}) when status in @terminal, do: :ok
  defp terminal(_run), do: {:error, :not_terminal}

  defp lock_old_reservations(run, cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(agent_run_id == ^run.id and status == :reserved and reserved_at < ^cutoff)
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read()
  end

  defp fail_operation(%{status: :running} = operation, failed, actor),
    do:
      Operations.fail_operation(operation, %{failure_id: failed.attention_failure_id},
        actor: actor
      )

  defp fail_operation(_operation, _failed, _actor), do: {:ok, :no_running_operation}
end

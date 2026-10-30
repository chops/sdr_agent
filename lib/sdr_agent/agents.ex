defmodule SdrAgent.Agents do
  @moduledoc """
  Agents bounded context: agent provenance (S2; ADR-0002, ADR-0004).

  Resources: `AgentDefinition`, `AgentRun`, `ModelInvocation`,
  `ToolInvocation`, `Decision` (S3; `ModelBudgetDay` in S6,
  `WireWitnessLink` in S12). Agents sits above Audit, Accounts and
  Operations and below Sales: lead and campaign ids are plain uuids here.

  Public API (every function takes `actor:` and runs through
  `SdrAgent.Audit.Guard`, so refused auditor mutations are audited):

    * definitions — `register_definition/2` (idempotent per name/version;
      a different hash is refused), `retire_definition/2`, `get_definition/2`;
    * runs — `create_run/2`, `start_run/2`, `set_run_phase/3`,
      `succeed_run/2`, `fail_run/3`, `exhaust_run_budget/3`, `cancel_run/2`,
      `reserve_model_call/2`, `get_run/2` (operator retry is
      `SdrAgent.SDR.retry_run/2`, S13b),
      `find_run_by_operation/2`, `active_runs_for_lead/2`, `list_runs/1`;
    * model calls — `reserve_model_invocation/3` (reserves the run budget,
      enforces the persisted daily limit, admits a real-model call against
      the owner's grants (C9, `SdrAgent.Agents.Admission`), stores the
      request Payload and numbers the call, in one transaction; a refusal
      is then recorded on its own), `daily_model_call_limit/0`,
      `daily_model_calls/1`,
      `mark_model_invocation_sent/2` (the Fake's sent boundary),
      `admit_launch/3` (C9-03: a ClaudeCLI call's launch admission and sent
      boundary), `get_model_invocation/2`, `complete_model_invocation/3`,
      `fail_model_invocation/3`, `mark_model_invocation_unknown/2` (each
      settles run usage in the same transaction), `list_model_invocations/2`,
      and `mark_terminal_run_sent_unknown/3` (L2 E1: a terminal run's old
      `sent` rows → unknown, ledger-only, never settled);
    * tool calls — `list_tool_invocations/2`, `start_tool_invocation/3`,
      `succeed_tool_invocation/3`,
      `fail_tool_invocation/3`, `mark_tool_invocation_unknown/2`;
    * decisions — `record_decision/2` (idempotent on its key; conflicting
      reuse fails), `list_decisions/2`;
    * wire witness (S12) — `link_wire_witness/2` (REC; append-only
      per-exchange lineage), `list_wire_witness_links/2`,
      `current_wire_witness_links/2`, `witness_status/2` (S12c), and
      `read_reconciliation_payloads/2` (REC; the only path to the scoped
      Payload read). Reconciliation itself: `SdrAgent.Agents.Witness`;
    * result release (R0-07) — `decide_result_release/2` (AGT; the one
      immutable `ModelResultRelease` of an invocation), `get_result_release/2`,
      `list_result_releases/1`, and `released_output/2`, the only business
      read of a generation-2 ClaudeCLI output (`SdrAgent.Agents.ReleasedOutput`);
    * real-model call grants (C9) — `create_grant/2`,
      `update_grant_terms/3`, `revoke_grant/3`, `release_allocation/3`
      (each an active human admin only, in one transaction, refusing a stale
      `expected_revision`), `list_grants/1`, `get_grant/2`, and
      `grant_usage/2` (the attempts consumed, derived from the charged
      ModelInvocations);
    * model profile switches (C2-02a, `SdrAgent.Agents.ProfileSwitches`) —
      `request_profile_switch/2` (a current human admin),
      `complete_profile_switch/3`, `fail_profile_switch/3`,
      `block_profile_switch/3` (`model_runtime` only; idempotent on the
      switch's `server_generation`), `get_profile_setting/1` and
      `list_profile_switches/1` (`ModelProfileSetting`, `ModelProfileSwitch`);
      C2-02b1: `drain_profile_switch/3` (AGT; `SdrAgent.Agents.ProfileSwitchDrain`),
      and the admission fence (`SdrAgent.Agents.Admission.SwitchFence`);
      C2-02b2β: `blocked_switch_facts/2` and `resolve_blocked_switch/3`
      (an active human admin only; the attended blocked → failed
      resolution, executed by the registered model coordinator).
    * run settings (C4, `docs/product/c4/readiness.md`) —
      `create_settings_revision/2` (an active human admin; append-only
      `SettingsRevision`, stale and raise-confirmation checks),
      `current_settings/1` (the settings page only), `run_settings/2` (the
      resolved settings of a run's `RunSettingsSnapshot`, the only read
      agents use), `run_settings_summary/2` (the run page's metadata-only
      view of a snapshot) and `settings_complete/2` (the assignment pre-check);
      limits and booking links at use are `SdrAgent.Agents.RunSettings`.
    * prototype seed (D-268) — `prototype_seed_settings_history/2` exposes
      fixed metadata-only history facts and `seed_prototype_settings_revision/3`
      invokes the existing seed action, only for a fresh live operator in
      the seed owner's transaction. Both are refusal-only in production.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query
  require Logger

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.NotFound
  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.SwitchFence
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.CalibrationFinish
  alias SdrAgent.Agents.Changes.BuildSettingsSnapshot
  alias SdrAgent.Agents.CalibrationRecovery
  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.Agents.ServerStarts
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettingsSnapshot
  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.Agents.ToolInvocation
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit.Checks.ReconciliationScope
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Repo

  @notifications {__MODULE__, :notifications}
  @provision_meta %{
    resource: SdrAgent.Agents.ModelCallGrant,
    action: :provision_prototype,
    guarded?: true,
    subject_id: nil
  }
  # ADR-0004: at most 200 model calls per UTC day; configuration may only lower it.
  @daily_model_call_limit 200

  resources do
    resource SdrAgent.Agents.AgentDefinition
    resource SdrAgent.Agents.AgentRun
    resource SdrAgent.Agents.ModelInvocation
    resource SdrAgent.Agents.ToolInvocation
    resource SdrAgent.Agents.Decision
    resource SdrAgent.Agents.WireWitnessLink
    resource SdrAgent.Agents.ModelCallGrant
    resource SdrAgent.Agents.ModelCallAllocation
    resource SdrAgent.Agents.ModelResultRelease
    resource SdrAgent.Agents.ModelProfileSetting
    resource SdrAgent.Agents.ModelProfileSwitch
    resource SdrAgent.Agents.ModelServerCounter
    resource SdrAgent.Agents.ModelServerStart
    resource SdrAgent.Agents.SettingsRevision
    resource SdrAgent.Agents.RunSettingsSnapshot
  end

  ## Definitions

  @doc "Registers a definition (KRN). Same name/version and hash returns the existing row."
  def register_definition(attrs, opts) do
    actor = Keyword.get(opts, :actor)

    guard(AgentDefinition, :register, nil, actor, fn ->
      AgentDefinition
      |> Ash.Changeset.for_create(:register, attrs, actor: actor)
      |> register(actor)
    end)
  end

  # Unauthorized callers get the action's own Forbidden error; authorized
  # ones get the existing row when name, version and hash match.
  defp register(changeset, actor) do
    with true <- Ash.can?(changeset, actor),
         {:ok, %AgentDefinition{} = existing} <- find_definition(changeset, actor) do
      if existing.definition_sha256 == Ash.Changeset.get_attribute(changeset, :definition_sha256),
        do: {:ok, existing},
        else: hash_conflict(existing)
    else
      false -> Ash.create(changeset)
      {:ok, nil} -> Ash.create(changeset)
      other -> other
    end
  end

  defp hash_conflict(existing) do
    {:error,
     Ash.Error.to_error_class(
       InvalidAttribute.exception(
         field: :definition,
         message: "#{existing.name} v#{existing.version} is registered with another hash"
       )
     )}
  end

  @doc "Retires an active definition (KRN)."
  def retire_definition(definition, opts), do: update(definition, :retire, %{}, opts)

  @doc """
  One AgentDefinition by id, within the actor's tenant (B1: a run's pinned
  definition, read by the agent and the run page).
  """
  def get_definition(id, opts) do
    actor = Keyword.get(opts, :actor)

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: AgentDefinition)}
      other -> other
    end
  end

  defp find_definition(changeset, actor) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^get.(:tenant_id) and name == ^get.(:name) and version == ^get.(:version)
    )
    |> Ash.read_one()
  end

  ## Runs

  @doc "Creates a queued run (AGT, SCH)."
  def create_run(attrs, opts), do: create(AgentRun, :create, attrs, opts)

  @doc "queued → running (AGT)."
  def start_run(run, opts), do: update(run, :start, %{}, opts)

  @doc "Changes the phase of a running run (AGT)."
  def set_run_phase(run, phase, opts), do: update(run, :set_phase, %{phase: phase}, opts)

  @doc "running → succeeded (AGT)."
  def succeed_run(run, opts), do: update(run, :succeed, %{}, opts)

  @doc """
  running → failed with `status_reason` and redacted `failure_reason` (AGT).
  A result-gate stop (`:witness_mismatch`, `:witness_unreconciled`) takes
  `witness_failure_id` and `release_id`; its finalizer passes `prelocked:`
  (its verified `SdrAgent.Agents.ReleaseDecision.Prelocked` context).
  """
  def fail_run(run, attrs, opts) do
    case Keyword.fetch(opts, :prelocked) do
      :error ->
        update(run, :fail, attrs, opts)

      {:ok, prelocked} ->
        actor = Keyword.get(opts, :actor)

        guard(AgentRun, :fail, run.id, actor, fn ->
          run
          |> Ash.Changeset.for_update(:fail, attrs,
            actor: actor,
            context: %{sdr_prelocked: prelocked}
          )
          |> Ash.update(return_notifications?: true)
          |> collect()
        end)
    end
  end

  @doc "running → budget_exhausted with `status_reason` (AGT)."
  def exhaust_run_budget(run, attrs, opts), do: update(run, :exhaust_budget, attrs, opts)

  @doc "queued | running → cancelled (ADM, REV, AGT)."
  def cancel_run(run, opts), do: update(run, :cancel, Keyword.get(opts, :attrs, %{}), opts)

  @doc "Atomically reserves one model call against the run budget (AGT)."
  def reserve_model_call(run, opts), do: update(run, :reserve_model_call, %{}, opts)

  @doc "Reads one run of the actor's tenant (not found otherwise)."
  def get_run(id, opts) do
    actor = Keyword.get(opts, :actor)

    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: AgentRun)}
      other -> other
    end
  end

  @doc """
  Runs of the actor's tenant, newest first (S10 Runs view); `lead_id:`
  narrows to one lead. Read policy: any present actor (AgentRun).
  """
  def list_runs(opts) do
    actor = Keyword.get(opts, :actor)

    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> then(fn query ->
      case Keyword.get(opts, :lead_id) do
        nil -> query
        lead_id -> Ash.Query.filter(query, lead_id == ^lead_id)
      end
    end)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read()
  end

  @doc "Queued or running runs of a lead (an active assignment)."
  def active_runs_for_lead(lead_id, opts) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: Keyword.get(opts, :actor))
    |> Ash.Query.filter(lead_id == ^lead_id and status in [:queued, :running])
    |> Ash.read()
  end

  @doc "The run executing an Operation (`operation_id`)."
  def find_run_by_operation(operation_id, opts) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: Keyword.get(opts, :actor))
    |> Ash.Query.filter(operation_id == ^operation_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: AgentRun)}
      other -> other
    end
  end

  ## Model invocations

  @doc """
  Reserves budget, stores the request body (`attrs.request`) and creates the
  `reserved` invocation numbered by the reservation — one transaction (AGT).

  C9: a ClaudeCLI reservation (with its reviewed `profile_id`) is admitted
  in the same transaction against the tenant's grants
  (`SdrAgent.Agents.Admission`), in the lock order run → candidate grants
  (`FOR SHARE`) → their allocations (`FOR SHARE`) → chain head, so it never
  waits for a grant or allocation row while holding the head: the one
  eligible allocation is written on the row with `ledger_generation` 2,
  passed to `:reserve` only through `AdmissionContext`. A refusal
  (`:no_usage_origin`, `:no_eligible_grant`, `:no_allocation`,
  `:ambiguous_allocation`, `{:budget_exhausted, :grant | :grant_day |
  :allocation}`) rolls the whole reservation back — no payload, invocation
  or counter change — and is then committed in its own transaction as one
  deduplicated `budget_exhausted` Failure and a `model.reservation.refused`
  event before `{:error, %Admission.Refused{reason: reason}}` — the exact
  receipt: reason, Failure, event, run and request id — is returned. Inputs may be atom- or
  string-keyed (not both for one field); caller-supplied `grant_id`,
  `allocation_id` and `ledger_generation` are dropped, and `provider`,
  `profile_id` and `purpose` are cast before the path is chosen. A Fake
  reservation records `profile_id: :fake` and needs no grant.

  The ADR-0004 daily limit is enforced here, persisted: after the run
  counter is reserved (run row lock), the tenant's chain head is locked and
  the ModelInvocations reserved in the current UTC day are counted; at the
  limit the whole reservation rolls back with
  `{:error, {:budget_exhausted, :daily}}` before any provider runs. Every
  reservation holds the chain-head lock until it commits, so concurrent
  reservations serialise and cannot both take the last unit. Attempts are
  never refunded.

  C2* operation snapshot entry `:reserve_model_invocation` (ADR-0005 C2*
  item 2), before the guard and the store observation.
  """
  def reserve_model_invocation(run, attrs, opts) do
    OperationSnapshot.enter(:reserve_model_invocation, fn ->
      actor = Keyword.get(opts, :actor)

      marker = Keyword.get(opts, :calibration)

      calibration =
        {CalibrationAdmission.scope(marker), CalibrationAdmission.claim(marker),
         CalibrationAdmission.binding(marker)}

      ModelInvocation
      |> guard(:reserve, run.id, actor, fn ->
        reserve_normalized(run, attrs, actor, calibration)
      end)
      |> refusal_recorded()
    end)
  end

  # The reservation rolled back; the refusal is committed on its own.
  defp refusal_recorded({:error, %Admission.Refusal{} = refusal}) do
    with {:ok, refused} <- Admission.record_refusal(refusal), do: {:error, refused}
  end

  defp refusal_recorded(result), do: result

  # R0-07 slice B (row B5'): the store observation — the admission gate's
  # only filesystem I/O — runs after input normalisation and before the
  # reservation takes any lock, and only for a caller an authorized,
  # tenant-scoped preflight (no row lock) shows may reserve on this run
  # (review MF3). Anyone else causes no I/O: the store stays unobserved and
  # the locked path, which stays authoritative, gives its usual answer.
  defp reserve_normalized(run, attrs, actor, calibration) do
    with {:ok, attrs} <- normalize_reserve(attrs) do
      {request, attrs} = Map.pop(attrs, :request)
      gate = gate_inputs(attrs, calibration, run, actor)
      transact(fn -> do_reserve_model_invocation(run, attrs, request, actor, gate) end)
    end
  end

  # `claim` is the console's launch-record claim carried by the same marker
  # (R0-07 E4c-2): recorded only with an admitted calibration tuple.
  defp gate_inputs(%{provider: :claude_cli} = attrs, {calibration, claim, binding}, run, actor) do
    if ModelProfiles.real?(Map.get(attrs, :profile_id)) do
      store = if may_reserve?(run, actor), do: Gate.observe_store(), else: :unobserved
      %{store: store, calibration: calibration, claim: claim, binding: binding}
    end
  end

  defp gate_inputs(_attrs, _calibration, _run, _actor), do: nil

  defp may_reserve?(%{id: run_id}, %SdrAgent.Actor{tenant_id: tenant_id} = actor)
       when is_binary(tenant_id) do
    with id when is_binary(id) <- uuid(run_id),
         {:ok, %AgentRun{} = run} <- tenant_run(id, actor) do
      Ash.can?({run, :reserve_model_call}, actor)
    else
      _denied -> false
    end
  rescue
    _error -> false
  end

  defp may_reserve?(_run, _actor), do: false

  defp tenant_run(id, actor) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  # A ClaudeCLI call with a reviewed real profile goes through admission
  # (lock order: run → candidate grants → their allocations → chain head; see
  # `SdrAgent.Agents.Admission`); the admitted charge reaches :reserve only
  # through `AdmissionContext`. Any other call keeps the S6 order (run →
  # chain head); the Fake records its own profile, and any other profile is
  # left to the :reserve validation to refuse.
  defp do_reserve_model_invocation(run, %{provider: :claude_cli} = attrs, request, actor, gate) do
    if ModelProfiles.real?(Map.get(attrs, :profile_id)),
      do: reserve_admitted(run, attrs, request, actor, gate),
      else: reserve(run, attrs, request, actor, %{})
  end

  defp do_reserve_model_invocation(run, %{provider: :fake} = attrs, request, actor, _gate),
    do: reserve(run, Map.put(attrs, :profile_id, :fake), request, actor, %{})

  defp do_reserve_model_invocation(run, attrs, request, actor, _gate),
    do: reserve(run, attrs, request, actor, %{})

  # The admission instant is read only once every lock is held, and is used
  # for the daily limit, eligibility, the grant's UTC day and `reserved_at`.
  defp reserve_admitted(run, attrs, request, actor, gate) do
    with {:ok, locked} <- lock_run(run.id, actor),
         {:ok, candidates} <- Admission.lock_candidates(locked, attrs.profile_id),
         {:ok, _head} <- Kernel.lock_head(locked.tenant_id),
         now = SdrAgent.Clock.utc_now(),
         {:ok, run} <- do_update(run, :reserve_model_call, %{}, actor),
         :ok <- check_daily_limit(run.tenant_id, now),
         {:ok, charge} <- Admission.admit(locked, attrs, now, candidates, gate) do
      context = AdmissionContext.context(Map.put(charge, :reserved_at, now))
      create_reserved(run, attrs, request, actor, context)
    end
  end

  defp reserve(run, attrs, request, actor, context) do
    with {:ok, run} <- do_update(run, :reserve_model_call, %{}, actor),
         :ok <- check_daily_limit(run.tenant_id) do
      create_reserved(run, attrs, request, actor, context)
    end
  end

  defp create_reserved(run, attrs, request, actor, context) do
    with {:ok, payload} <- store(request, actor) do
      attrs =
        Map.merge(attrs, %{
          agent_run_id: run.id,
          sequence_in_run: run.budget.model_calls_reserved,
          request_sha256: payload.sha256
        })

      ModelInvocation
      |> Ash.Changeset.for_create(:reserve, attrs, actor: actor, context: context)
      |> Ash.create(return_notifications?: true)
      |> collect()
    end
  end

  # Reservation inputs are normalised before dispatch, so the admission path
  # is chosen on cast values: keys may be atoms or strings (never both for one
  # field), the governed charge fields are dropped in either form, and
  # `provider`, `profile_id` and `purpose` are cast with their attribute types.
  @charge_fields [:grant_id, :allocation_id, :ledger_generation]
  @dispatch_fields [:provider, :profile_id, :purpose]

  defp normalize_reserve(attrs) do
    attrs = Map.new(attrs)

    with :ok <- distinct_keys(attrs) do
      attrs
      |> Map.drop(@charge_fields ++ Enum.map(@charge_fields, &Atom.to_string/1))
      |> cast_fields([:request | @dispatch_fields])
    end
  end

  defp cast_fields(attrs, []), do: {:ok, attrs}

  defp cast_fields(attrs, [field | fields]) do
    with {:ok, attrs} <- cast_field(field, attrs), do: cast_fields(attrs, fields)
  end

  defp distinct_keys(attrs) do
    duplicate =
      Enum.find(Map.keys(attrs), fn
        key when is_binary(key) -> Map.has_key?(attrs, existing_atom(key))
        _key -> false
      end)

    if duplicate, do: {:error, invalid_input(duplicate, "is given twice")}, else: :ok
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp cast_field(field, attrs) do
    {value, attrs} = Map.pop(attrs, Atom.to_string(field), Map.get(attrs, field))

    case {field, value} do
      {_field, nil} -> {:ok, Map.delete(attrs, field)}
      {:request, request} -> {:ok, Map.put(attrs, :request, request)}
      {field, value} -> cast_attribute(field, value, attrs)
    end
  end

  defp cast_attribute(field, value, attrs) do
    %{type: type, constraints: constraints} = Ash.Resource.Info.attribute(ModelInvocation, field)

    with {:ok, cast} when not is_nil(cast) <- Ash.Type.cast_input(type, value, constraints),
         {:ok, cast} <- Ash.Type.apply_constraints(type, cast, constraints) do
      {:ok, Map.put(attrs, field, cast)}
    else
      _ -> {:error, invalid_input(field, "is invalid")}
    end
  end

  defp invalid_input(field, message),
    do: Ash.Error.to_error_class(InvalidAttribute.exception(field: field, message: message))

  @doc "The effective daily model-call limit: `min(config, 200)` (ADR-0004)."
  def daily_model_call_limit do
    case Application.get_env(:sdr_agent, :daily_model_call_limit) do
      limit when is_integer(limit) and limit >= 0 ->
        Elixir.Kernel.min(limit, @daily_model_call_limit)

      _ ->
        @daily_model_call_limit
    end
  end

  @doc """
  ModelInvocations of `tenant_id` reserved in the UTC day of `at` (default:
  now, `SdrAgent.Clock`).
  """
  def daily_model_calls(tenant_id, at \\ SdrAgent.Clock.utc_now()) do
    today = DateTime.to_date(at)
    from = DateTime.new!(today, ~T[00:00:00.000000], "Etc/UTC")
    until = DateTime.add(from, 1, :day)

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and reserved_at >= ^from and reserved_at < ^until)
    |> Ash.count!()
  end

  # Runs inside the reservation transaction (see reserve_model_invocation/3).
  defp check_daily_limit(tenant_id, at \\ SdrAgent.Clock.utc_now()) do
    with {:ok, _head} <- Kernel.lock_head(tenant_id) do
      if daily_model_calls(tenant_id, at) < daily_model_call_limit(),
        do: :ok,
        else: {:error, {:budget_exhausted, :daily}}
    end
  end

  @doc """
  reserved → sent (AGT). The Fake's sent boundary; a ClaudeCLI call is sent
  only by `admit_launch/3`.
  """
  def mark_model_invocation_sent(invocation, opts),
    do: update(invocation, :mark_sent, %{}, opts)

  @doc """
  AGT: admits the reserved ClaudeCLI invocation `invocation_id` for launch
  under the model server's `effective_profile`, just before the server
  opens the port (C9-03; R0 readiness packet, "Changed backend action
  contracts"). The only sent boundary of a ClaudeCLI call.

  One guarded transaction, as `agent_runtime` of a tenant (any other actor
  is `Ash.Error.Forbidden`, audited as `authz.denied`). Before any lock the
  witness store root is observed (`Admission.Gate.observe_store/0`, the
  only filesystem I/O; R0-07 slice B, row B5'). Lock order: the run row
  (`FOR UPDATE`), the run's Operation (`FOR SHARE`, if any; R0-07 slice B,
  row B1), the invocation row (`FOR UPDATE`; run and invocation re-read in
  the actor's tenant), then the charged grant and allocation `FOR SHARE`
  (`Admission.lock_charge/1`, the reservation's order), then the chain head
  explicitly; only then is `now` read and are the terms read. Grant
  editors lock grant → allocations → head and never a run or invocation, so
  either an edit commits first (the launch is refused) or the launch does
  (it proceeds; a later revocation does not stop a launched call).

    * **Identity and state refusals** change nothing and return `{:error,
      reason}`: `:invocation_not_found` (missing, malformed or another
      tenant's id), `:invocation_not_claude_cli`, `:invocation_not_reserved`
      (a replayed sent, in-flight or terminal row), and for the option
      `calibration_launch:` (R0-07 packet 8.13; `Admission.calibration_launch/1`)
      `:calibration_launch_invalid` (present but malformed, an explicit
      `nil` included; checked before any lock) and
      `:calibration_target_mismatch` (the locked invocation's run or tenant
      is not the expected one). Each is then recorded as a
      `model.launch.refused` event of the actor's tenant only. The option
      can only add refusals; without it a launch is admitted as before.
    * **A stopped run** (`:run_not_running_at_launch`): the row is failed
      and never sent, and no Failure is opened (the stop is already its
      cause): `{:error, :run_not_running_at_launch}`.
    * **Every other refusal** of an owned, reserved row
      (`Admission.launch_check/5`: generation, profile, then the R0-07
      admission gate — calibration authority and predecessors, gate mode,
      store root, promoted tuple — then grant status and window, grant
      profiles, allocation grant, profile restriction, usage bucket,
      availability; never room, which was charged at reservation) moves it
      reserved → failed (never sent), opens one critical `provider_error`
      Failure whose subject is the **run** (its `operation_id` the run's
      Operation) and appends `model.launch.refused` (the reason, check and
      Failure, with the invocation's `idempotency_key`), all in this
      transaction. It returns the typed receipt `{:error, %Admission.Refused{
      stage: :launch}}`, from which the run stops `:model_not_admitted`
      linking exactly that Failure (R0-07 slice B, row B1).
    * **Success** marks it sent: `{:ok, invocation}`.

  C2* operation snapshot entry `:admit_launch` (ADR-0005 C2* item 2): it
  runs in the model server's process, so each launch is its own owner,
  before `Guard.run/3`.
  """
  def admit_launch(invocation_id, effective_profile, opts) do
    OperationSnapshot.enter(:admit_launch, fn ->
      actor = Keyword.get(opts, :actor)

      meta = %{
        resource: ModelInvocation,
        action: :admit_launch,
        guarded?: true,
        subject_id: uuid(invocation_id)
      }

      expected = Admission.calibration_launch(opts)

      Guard.run(meta, actor, fn -> launch(invocation_id, effective_profile, actor, expected) end)
    end)
  end

  defp launch(
         id,
         profile,
         %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant} = actor,
         expected
       )
       when is_binary(tenant) do
    # Review MF3: the store is observed (filesystem I/O) only for an
    # invocation the preflight finds in the actor's tenant; the locked
    # path stays authoritative.
    # L2 E3: an invalid launch option is refused before any target read.
    store =
      if expected != :invalid and match?({:ok, _}, launch_target(id, actor)),
        do: Gate.observe_store(),
        else: :unobserved

    case audit_transact(fn -> launch_locked(id, profile, actor, store, expected) end) do
      {:ok, {:sent, sent}} ->
        {:ok, sent}

      {:ok, {:refused, %Admission.Refused{} = refused}} ->
        {:error, refused}

      {:ok, {:refused, reason}} ->
        {:error, reason}

      {:error, {:launch_refused, reason, own_id}} ->
        record_launch_refusal(reason, own_id, id, profile, actor)
        {:error, reason}

      {:error, error} ->
        {:error, error}
    end
  end

  defp launch(_id, _profile, _actor, _expected), do: {:error, Ash.Error.Forbidden.exception([])}

  defp launch_locked(id, profile, actor, store, expected) do
    with :ok <- valid_expectation(expected),
         {:ok, target} <- launch_target(id, actor),
         {:ok, run} <- lock_tenant_run(target.agent_run_id, actor),
         :ok <- Admission.lock_operation_share(run.operation_id),
         {:ok, invocation} <- lock_invocation(target.id, actor),
         :ok <- calibration_target(invocation, actor, expected),
         :ok <- launch_state(invocation),
         :ok <- Admission.lock_charge(invocation),
         {:ok, _head} <- Kernel.lock_head(actor.tenant_id) do
      # The launch instant is read only once every lock is held.
      run
      |> Admission.launch_check(invocation, profile, SdrAgent.Clock.utc_now(), store, expected)
      |> admit_or_refuse(run, invocation, profile, actor)
    end
  end

  defp valid_expectation(:invalid), do: launch_refused(:calibration_launch_invalid)
  defp valid_expectation(_expected), do: :ok

  # Packet 8.13 C7: an exempted call's target is the expected run's own
  # invocation in the expected tenant; anything else changes nothing.
  defp calibration_target(_invocation, _actor, nil), do: :ok
  defp calibration_target(_invocation, _actor, :ordinary), do: :ok

  defp calibration_target(invocation, actor, expected) do
    if invocation.agent_run_id == expected.run_id and invocation.tenant_id == expected.tenant_id and
         actor.tenant_id == expected.tenant_id,
       do: :ok,
       else: launch_refused(:calibration_target_mismatch)
  end

  defp admit_or_refuse(:ok, _run, invocation, _profile, actor) do
    with {:ok, sent} <- do_update(invocation, :mark_sent, %{}, actor), do: {:ok, {:sent, sent}}
  end

  defp admit_or_refuse({:error, reason, check}, run, invocation, profile, actor),
    do: refuse_launch(run, invocation, reason, check, profile, actor)

  # An unlocked read only to find the run to lock first; the row is re-read
  # under its own lock.
  defp launch_target(id, actor) do
    case uuid(id) do
      nil -> launch_refused(:invocation_not_found)
      id -> id |> tenant_invocation(actor) |> Ash.read_one() |> found()
    end
  end

  defp lock_invocation(id, actor) do
    id
    |> tenant_invocation(actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> found()
  end

  defp tenant_invocation(id, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
  end

  defp lock_tenant_run(run_id, actor) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> found()
  end

  defp found({:ok, nil}), do: launch_refused(:invocation_not_found)
  defp found(other), do: other

  defp launch_state(%{provider: :claude_cli, status: :reserved}), do: :ok

  defp launch_state(%{provider: :claude_cli} = invocation),
    do: launch_refused(:invocation_not_reserved, invocation.id)

  defp launch_state(invocation), do: launch_refused(:invocation_not_claude_cli, invocation.id)

  defp launch_refused(reason, own_id \\ nil), do: {:error, {:launch_refused, reason, own_id}}

  defp refuse_launch(run, invocation, reason, check, profile, actor, extra \\ %{}) do
    error = %{
      "kind" => "launch_refused",
      "reason" => Atom.to_string(reason),
      "check" => Admission.check_name(check)
    }

    failure = %{
      operation_id: run.operation_id,
      subject_resource: inspect(AgentRun),
      subject_id: run.id,
      class: :provider_error,
      severity: :critical,
      retryable: false,
      message:
        "model call refused at launch: #{reason} (#{Admission.check_label(check)}); the reserved call was failed " <>
          "and never sent",
      detail:
        SdrAgent.Audit.Canonical.encode!(%{
          "kind" => "model_launch_refused",
          "reason" => Atom.to_string(reason),
          "check" => Admission.check_name(check),
          "model_invocation_id" => invocation.id,
          "grant_id" => invocation.grant_id,
          "reserved_profile" => profile_name(invocation.profile_id),
          "effective_profile" => profile_name(profile)
        })
    }

    with {:ok, _failed} <- do_update(invocation, :fail, %{error: error}, actor) do
      launch_receipt(reason, check, failure, {run, invocation, profile}, actor, extra)
    end
  end

  # A run stopped while its call was queued already has its own cause (its
  # stop's Failure, or an operator's cancel or a success, which need none):
  # the refused call is failed, but no second attention item is opened.
  defp launch_receipt(
         :run_not_running_at_launch = reason,
         _check,
         _failure,
         _call,
         _actor,
         _extra
       ),
       do: {:ok, {:refused, reason}}

  # R0-07 slice B (row B1): the one Failure of the run and the launch
  # event naming it, under the head already held (their FKs find the run,
  # its Operation and the invocation locked), committed with the failed row.
  defp launch_receipt(reason, check, failure, {run, invocation, profile}, actor, extra) do
    event = %{
      event_type: "model.launch.refused",
      category: :model,
      subject_resource: inspect(ModelInvocation),
      subject_id: invocation.id,
      action: "admit_launch",
      agent_run_id: run.id,
      model_invocation_id: invocation.id,
      correlation_id: run.correlation_id,
      idempotency_key: invocation.idempotency_key,
      payload: %{
        "reason" => Atom.to_string(reason),
        "check" => Admission.check_name(check),
        "effective_profile" => profile_name(profile),
        "reserved_profile" => profile_name(invocation.profile_id)
      }
    }

    event = update_in(event.payload, &Map.merge(&1, extra))

    with {:ok, failure} <- SdrAgent.Operations.open_failure(failure, actor: actor),
         event = put_in(event, [:payload, "failure_id"], failure.id),
         {:ok, event} <- SdrAgent.Audit.append(event, actor: actor) do
      {:ok,
       {:refused,
        %Admission.Refused{
          reason: reason,
          check: check,
          failure_id: failure.id,
          event_id: event.id,
          agent_run_id: run.id,
          request_id: invocation.idempotency_key,
          stage: :launch
        }}}
    end
  end

  ## Model profile switch drain (C2-02b1)

  @doc """
  AGT: drains the open model profile switch `switch` —
  `%{server_generation, timeout_ms}`: refuses every row reserved before it,
  stops each refused row's run `:model_not_admitted` and settles its
  Operation, waits (bounded) for the tenant's sent rows to settle, and
  reports counts only. See `SdrAgent.Agents.ProfileSwitchDrain`.
  """
  def drain_profile_switch(switch, attrs, opts) do
    actor = Keyword.get(opts, :actor)

    # Through the guard, so an auditor's attempt is refused before anything
    # runs and audited exactly once (S2 auditor contract).
    guard(SdrAgent.Agents.ModelProfileSwitch, :drain, subject_id(switch), actor, fn ->
      SdrAgent.Agents.ProfileSwitchDrain.drain(switch, attrs, opts)
    end)
  end

  @doc false
  # The drain's refusal of one reserved row (`ProfileSwitchDrain` only), in
  # one transaction in launch's lock order (run → Operation share →
  # invocation → charge → chain head). After the head, the named switch is
  # revalidated by a fresh non-locking read (pending at `generation`) and
  # the row must have been reserved before that switch's request. Then the
  # row is refused exactly as a launch refusal (`:profile_switch_fenced`,
  # `:reserved_before_switch`, the switch id in the event) and its run is
  # stopped `:model_not_admitted` linking that Failure; a run no longer
  # running gets the `:run_not_running_at_launch` treatment. Returns
  # `{:ok, {:refused, run_id}}`, `{:ok, :not_running}`, `{:ok, :skipped}`
  # (the row is no longer reserved) or `{:error, reason}` with nothing
  # written.
  #
  # `step` (the drain's budget) runs before each lock and the writes:
  # `:ok`, or `{:error, :drain_timeout}` to roll back unchanged.
  def refuse_reserved_for_switch(invocation_id, switch_id, generation, actor, step \\ &ok/0) do
    guard(ModelInvocation, :refuse_reserved_for_switch, subject_id(invocation_id), actor, fn ->
      refuse_reserved(invocation_id, switch_id, generation, actor, step)
    end)
  end

  defp refuse_reserved(
         invocation_id,
         switch_id,
         generation,
         %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant} = actor,
         step
       )
       when is_binary(tenant) do
    audit_transact(fn ->
      drain_refuse_locked(invocation_id, switch_id, generation, actor, step)
    end)
  end

  defp refuse_reserved(_invocation_id, _switch_id, _generation, _actor, _step),
    do: {:error, Ash.Error.Forbidden.exception([])}

  defp ok, do: :ok

  defp subject_id(%{id: id}) when is_binary(id), do: id
  defp subject_id(id) when is_binary(id), do: id
  defp subject_id(_other), do: nil

  defp drain_refuse_locked(id, switch_id, generation, actor, step) do
    with :ok <- step.(),
         {:ok, target} <- launch_target(id, actor),
         :ok <- step.(),
         {:ok, run} <- lock_tenant_run(target.agent_run_id, actor),
         :ok <- step.(),
         :ok <- Admission.lock_operation_share(run.operation_id),
         :ok <- step.(),
         {:ok, invocation} <- lock_invocation(target.id, actor),
         :ok <- launch_state(invocation),
         :ok <- step.(),
         :ok <- Admission.lock_charge(invocation),
         :ok <- step.(),
         {:ok, _head} <- Kernel.lock_head(actor.tenant_id),
         :ok <- step.(),
         :ok <- SwitchFence.named_open(actor.tenant_id, switch_id, generation),
         :ok <- SwitchFence.before_request(actor.tenant_id, invocation.id, switch_id),
         :ok <- step.() do
      drain_refuse(run, invocation, switch_id, actor)
    else
      {:error, {:launch_refused, _reason, _own_id}} -> {:ok, :skipped}
      other -> other
    end
  end

  defp drain_refuse(%{status: :running} = run, invocation, switch_id, actor) do
    reason = :profile_switch_fenced
    check = :reserved_before_switch
    extra = %{"switch_id" => switch_id}

    with {:ok, {:refused, refused}} <-
           refuse_launch(run, invocation, reason, check, invocation.profile_id, actor, extra),
         {:ok, _stopped} <-
           do_update(
             run,
             :fail,
             %{
               status_reason: :model_not_admitted,
               failure_reason:
                 "model call not admitted (drain): #{Admission.reason_name(reason)} (#{check})",
               refusal_failure_id: refused.failure_id,
               refusal_request_id: refused.request_id
             },
             actor
           ) do
      {:ok, {:refused, run.id}}
    end
  end

  defp drain_refuse(run, invocation, switch_id, actor) do
    with {:ok, {:refused, _reason}} <-
           refuse_launch(
             run,
             invocation,
             :run_not_running_at_launch,
             run.status,
             invocation.profile_id,
             actor,
             %{"switch_id" => switch_id}
           ),
         do: {:ok, :not_running}
  end

  # Metadata only, in the actor's own tenant; the refusal itself changed
  # nothing, so a tenant without an audit chain records nothing.
  defp record_launch_refusal(reason, own_id, attempted, profile, actor) do
    event = %{
      event_type: "model.launch.refused",
      category: :model,
      subject_resource: inspect(ModelInvocation),
      subject_id: uuid(attempted),
      action: "admit_launch",
      model_invocation_id: own_id,
      payload: %{"reason" => Atom.to_string(reason), "effective_profile" => profile_name(profile)}
    }

    case SdrAgent.Audit.append(event, actor: actor) do
      {:ok, _event} ->
        :ok

      {:error, error} ->
        Logger.warning("model.launch.refused (#{reason}) was not audited: #{inspect(error)}")
    end
  end

  defp profile_name(profile) when is_atom(profile) and not is_nil(profile),
    do: Atom.to_string(profile)

  defp profile_name(_profile), do: nil

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_id), do: nil

  @doc "One model invocation of the actor's tenant, read fresh (not found otherwise)."
  def get_model_invocation(id, opts) do
    actor = Keyword.get(opts, :actor)

    case uuid(id) do
      nil ->
        {:error, NotFound.exception(resource: ModelInvocation)}

      id ->
        id
        |> tenant_invocation(actor)
        |> Ash.read_one()
        |> case do
          {:ok, nil} -> {:error, NotFound.exception(resource: ModelInvocation)}
          other -> other
        end
    end
  end

  @doc "sent → completed, storing the verbatim `response` and settling usage (AGT)."
  def complete_model_invocation(invocation, attrs, opts) do
    finish_model_invocation(invocation, :complete, attrs, opts)
  end

  @doc "reserved | sent → failed with `error` (AGT); a sent call is counted as used."
  def fail_model_invocation(invocation, attrs, opts) do
    finish_model_invocation(invocation, :fail, attrs, opts)
  end

  @doc "sent → unknown on crash recovery (AGT); never re-sent, counted as used."
  def mark_model_invocation_unknown(invocation, opts) do
    finish_model_invocation(invocation, :mark_unknown, %{}, opts)
  end

  @doc """
  L2 E1 (AGT; `SdrAgent.SDR.StaleRunSweeper` case (c)): marks unknown each
  `sent` invocation of the terminal, non-proof run `run_id` whose `sent_at`
  is strictly before now minus `stale_after_seconds`, through the existing
  `:mark_unknown` action. Ledger-only: the run is not settled or written,
  its counters stay as they are, the charge stays in `grant_usage/2`, and
  no Failure, Operation, release, lease or retry follows. It is not
  cleanup proof.

  One transaction: the run `FOR UPDATE` (tenant-scoped), then every `sent`
  row of the run `FOR UPDATE` in sequence order, before the first append.
  Recorded calibration authority on any invocation of the run
  (`Admission.Gate.reservation_authority/1`) refuses the whole run.
  Returns `{:ok, count}`, or `{:error, reason}` with nothing written:
  `:invalid_stale_after`, `:run_not_found` (also a foreign tenant's run),
  `:not_terminal`, `:proof_run`, `:calibration_authority`,
  `:authority_unbindable`. Any principal but the tenant's agent runtime is
  `Ash.Error.Forbidden`.
  """
  def mark_terminal_run_sent_unknown(run_id, stale_after_seconds, opts) do
    actor = Keyword.get(opts, :actor)
    meta = %{resource: AgentRun, action: :mark_terminal_run_sent_unknown, subject_id: run_id}

    Guard.run(meta, actor, fn -> checked_normalize(run_id, stale_after_seconds, actor) end)
  end

  # The principal, the grace and the id are checked before any read.
  defp checked_normalize(run_id, seconds, actor) do
    with :ok <- runtime_actor(actor),
         :ok <- grace(seconds),
         {:ok, run_id} <- run_uuid(run_id) do
      transact(fn -> normalize_terminal_sent(run_id, seconds, actor) end)
    end
  end

  @terminal_runs [:succeeded, :failed, :budget_exhausted, :cancelled]

  defp runtime_actor(%SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant_id})
       when is_binary(tenant_id) do
    if uuid(tenant_id), do: :ok, else: {:error, Ash.Error.Forbidden.exception([])}
  end

  defp runtime_actor(_actor), do: {:error, Ash.Error.Forbidden.exception([])}

  defp grace(seconds) when is_integer(seconds) and seconds > 0, do: :ok
  defp grace(_seconds), do: {:error, :invalid_stale_after}

  defp run_uuid(run_id) do
    case uuid(run_id) do
      nil -> {:error, :run_not_found}
      id -> {:ok, id}
    end
  end

  defp normalize_terminal_sent(run_id, seconds, actor) do
    with {:ok, run} <- lock_e1_run(run_id, actor),
         :ok <- terminal_non_proof(run),
         cutoff = DateTime.add(SdrAgent.Clock.utc_now(), -seconds, :second),
         {:ok, sent} <- lock_sent_invocations(run, actor),
         {:ok, invocations} <- run_invocations(run, actor),
         :ok <- no_recorded_authority(invocations) do
      sent
      |> Enum.filter(&(&1.sent_at && DateTime.compare(&1.sent_at, cutoff) == :lt))
      |> Enum.reduce_while({:ok, 0}, &mark_unknown_counted(&1, &2, actor))
    end
  end

  # The existing :mark_unknown action only (no settle/2); stops at the
  # first error, which rolls the whole run back.
  defp mark_unknown_counted(invocation, {:ok, count}, actor) do
    case do_update(invocation, :mark_unknown, %{}, actor) do
      {:ok, _unknown} -> {:cont, {:ok, count + 1}}
      error -> {:halt, error}
    end
  end

  defp lock_e1_run(run_id, actor) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^run_id and tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :run_not_found}
      other -> other
    end
  end

  defp terminal_non_proof(%{status: status}) when status not in @terminal_runs,
    do: {:error, :not_terminal}

  defp terminal_non_proof(%{usage_origin: :proof}), do: {:error, :proof_run}
  defp terminal_non_proof(_run), do: :ok

  defp lock_sent_invocations(run, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and agent_run_id == ^run.id and status == :sent
    )
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read()
  end

  defp run_invocations(run, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id and agent_run_id == ^run.id)
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.read()
  end

  defp no_recorded_authority(invocations) do
    Enum.reduce_while(invocations, :ok, fn invocation, :ok ->
      case authority(invocation.ledger_generation, Gate.reservation_authority(invocation)) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp authority(_generation, {:recorded, _entry}), do: {:error, :calibration_authority}
  defp authority(_generation, :no_tuple), do: :ok
  defp authority(1, :no_event), do: :ok
  defp authority(_generation, _no_event_or_invalid), do: {:error, :authority_unbindable}

  @doc "Invocations of a run, in call order."
  def list_model_invocations(run_id, opts) do
    actor = Keyword.get(opts, :actor)

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(agent_run_id == ^run_id)
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.read()
  end

  @doc "Tool invocations of a run, in call order (S10 run view)."
  def list_tool_invocations(run_id, opts) do
    actor = Keyword.get(opts, :actor)

    ToolInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(agent_run_id == ^run_id)
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.read()
  end

  defp finish_model_invocation(invocation, action, attrs, opts) do
    actor = Keyword.get(opts, :actor)
    {response, attrs} = Map.pop(Map.new(attrs), :response)

    guard(ModelInvocation, action, invocation.id, actor, fn ->
      transact(fn -> do_finish_model_invocation(invocation, action, attrs, response, actor) end)
    end)
  end

  # The run is locked before the first append (ADR-0009): settlement writes
  # invocation → chain → run, and the stale-run sweeper locks run →
  # invocations (review #25); both now take the run row first.
  defp do_finish_model_invocation(invocation, action, attrs, response, actor) do
    with {:ok, _run} <- lock_run(invocation.agent_run_id, actor),
         {:ok, attrs} <- put_body(attrs, :response_sha256, response, actor),
         {:ok, done} <- do_update(invocation, action, attrs, actor),
         {:ok, _run} <- settle(done, actor) do
      {:ok, done}
    end
  end

  defp lock_run(run_id, actor) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: AgentRun)}
      other -> other
    end
  end

  defp settle(%{sent_at: nil}, _actor), do: {:ok, :not_sent}

  defp settle(invocation, actor) do
    tokens =
      case invocation.usage do
        %{input_tokens: input, output_tokens: output} -> input + output
        _ -> 0
      end

    with {:ok, run} <- Ash.get(AgentRun, invocation.agent_run_id, actor: actor) do
      do_update(run, :settle_model_call, %{calls: 1, tokens: tokens}, actor)
    end
  end

  ## Tool invocations

  @doc """
  Counts the tool call against the run budget, stores the input body
  (`attrs.input`) and creates the `started` invocation (AGT).
  """
  def start_tool_invocation(run, attrs, opts) do
    actor = Keyword.get(opts, :actor)
    {input, attrs} = Map.pop(Map.new(attrs), :input)

    guard(ToolInvocation, :start, run.id, actor, fn ->
      transact(fn -> do_start_tool_invocation(run, attrs, input, actor) end)
    end)
  end

  defp do_start_tool_invocation(run, attrs, input, actor) do
    with {:ok, run} <- do_update(run, :record_tool_call, %{}, actor),
         {:ok, payload} <- store(input, actor) do
      attrs =
        Map.merge(attrs, %{
          agent_run_id: run.id,
          sequence_in_run: run.budget.tool_calls_used,
          input_sha256: payload.sha256
        })

      ToolInvocation
      |> Ash.Changeset.for_create(:start, attrs, actor: actor)
      |> Ash.create(return_notifications?: true)
      |> collect()
    end
  end

  @doc "started → succeeded with `output` body and external request refs (AGT)."
  def succeed_tool_invocation(invocation, attrs, opts),
    do: finish_tool_invocation(invocation, :succeed, attrs, opts)

  @doc "started → failed with `error` (AGT)."
  def fail_tool_invocation(invocation, attrs, opts),
    do: finish_tool_invocation(invocation, :fail, attrs, opts)

  @doc "started → unknown (AGT)."
  def mark_tool_invocation_unknown(invocation, opts),
    do: finish_tool_invocation(invocation, :mark_unknown, %{}, opts)

  defp finish_tool_invocation(invocation, action, attrs, opts) do
    actor = Keyword.get(opts, :actor)
    {output, attrs} = Map.pop(Map.new(attrs), :output)

    guard(ToolInvocation, action, invocation.id, actor, fn ->
      transact(fn -> do_finish_tool_invocation(invocation, action, attrs, output, actor) end)
    end)
  end

  defp do_finish_tool_invocation(invocation, action, attrs, output, actor) do
    with {:ok, attrs} <- put_body(attrs, :output_sha256, output, actor) do
      do_update(invocation, action, attrs, actor)
    end
  end

  ## Decisions

  @doc """
  Records a decision (each system actor only its own kinds). `attrs.inputs`
  is the exact input snapshot. Recording an identical decision again
  (same idempotency key and replay fingerprint) returns the existing row;
  reusing the key for a different decision fails with
  `SdrAgent.Agents.Errors.IdempotencyConflict` inside `Ash.Error.Invalid`.
  """
  def record_decision(attrs, opts) do
    create(Decision, :record, attrs, opts, Map.get(attrs, :subject_id))
  end

  @doc "One Decision by id, within the actor's tenant (e.g. a delivery's send gate, S13)."
  def get_decision(id, opts) do
    actor = Keyword.get(opts, :actor)

    Decision
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: Decision)}
      other -> other
    end
  end

  @doc "Decisions of a run, oldest first."
  def list_decisions(run_id, opts) do
    actor = Keyword.get(opts, :actor)

    Decision
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(agent_run_id == ^run_id)
    |> Ash.Query.sort(decided_at: :asc)
    |> Ash.read()
  end

  ## Wire witness (S12)

  @doc """
  Records the link of one witnessed exchange of a terminal ClaudeCLI
  invocation (REC). `attrs`: `model_invocation_id`, `proxy_record_ref`,
  optional raw `proxy_request_sha256`/`proxy_response_sha256`,
  `link_status`, `method`, `evidence`, and `supersedes_id` for a successor
  of the exchange's current link. See `SdrAgent.Agents.WireWitnessLink`.
  """
  def link_wire_witness(attrs, opts) do
    create(WireWitnessLink, :link, attrs, opts, Map.get(attrs, :model_invocation_id))
  end

  @doc "Every link (all lineage rows) of an invocation in the actor's tenant, oldest first."
  def list_wire_witness_links(invocation_id, opts) do
    invocation_id |> links_query(opts) |> Ash.read()
  end

  @doc "The current link (no successor) of each exchange of an invocation, oldest first."
  def current_wire_witness_links(invocation_id, opts) do
    invocation_id
    |> links_query(opts)
    |> Ash.Query.filter(not exists(successors, true))
    |> Ash.read()
  end

  @doc """
  The invocation-level wire-witness answer (S12 C1) over its current links:
  `{:ok, :unwitnessed | :inferred | :reconciled | :mismatch}`. See
  `SdrAgent.Agents.Witness.status/1`.
  """
  def witness_status(invocation_id, opts) do
    with {:ok, links} <- current_wire_witness_links(invocation_id, opts) do
      {:ok, SdrAgent.Agents.Witness.status(links)}
    end
  end

  defp links_query(invocation_id, opts) do
    WireWitnessLink
    |> GuardedCall.read_query(opts)
    |> Ash.Query.filter(model_invocation_id == ^invocation_id)
    |> Ash.Query.sort(recorded_at: :asc, id: :asc)
  end

  @doc """
  REC: returns `%{request: binary, response: binary | nil}` — the stored
  application bodies of one invocation, for wire-witness reconciliation
  (S12 supplementary ruling S1–S3).

  The invocation is re-read by id in the actor's tenant (a passed struct's
  fields are never trusted); only its own request/response hashes enter the
  private scope of `SdrAgent.Audit.Payload` `:read_reconciliation_content`,
  whose recorded purpose is fixed. Each body read appends a `payload_view`
  AuditAccess under REC's identity first and fails closed. A guarded call:
  every denial is audited. Callers keep this outside DB mutation locks.
  """
  def read_reconciliation_payloads(invocation, opts) do
    actor = Keyword.get(opts, :actor)
    id = invocation_id(invocation)

    meta = %{
      resource: ModelInvocation,
      action: :read_reconciliation_payloads,
      guarded?: true,
      subject_id: id
    }

    Guard.run(meta, actor, fn ->
      with {:ok, invocation} <- GuardedCall.get(ModelInvocation, id, actor: actor),
           scope = reconciliation_scope(invocation),
           {:ok, request} <- read_scoped(invocation.request_sha256, scope, actor),
           {:ok, response} <- read_scoped(invocation.response_sha256, scope, actor) do
        {:ok, %{request: request, response: response}}
      end
    end)
  end

  defp invocation_id(%ModelInvocation{id: id}), do: id
  defp invocation_id(id) when is_binary(id), do: id
  defp invocation_id(_invocation), do: nil

  defp reconciliation_scope(invocation) do
    ReconciliationScope.context(%{
      tenant_id: invocation.tenant_id,
      model_invocation_id: invocation.id,
      sha256s: [invocation.request_sha256, invocation.response_sha256]
    })
  end

  defp read_scoped(nil, _scope, _actor), do: {:ok, nil}

  defp read_scoped(sha256, scope, actor) do
    Payload
    |> Ash.ActionInput.for_action(:read_reconciliation_content, %{sha256: sha256},
      actor: actor,
      context: scope
    )
    |> Ash.run_action()
  end

  ## Result release (R0-07)

  @doc """
  AGT: decides the one immutable release of a model output. `attrs`:
  `model_invocation_id`, `disposition`, `reason`, optional
  `wire_witness_link_id` and (calibration latches only) `evidence_sha256`;
  `context:` carries the test-seam calibration context; `prelocked:` the
  finalizer's verified `SdrAgent.Agents.ReleaseDecision.Prelocked` context
  (no fresh lock requests; refused unless it matches). An identical replay
  returns the existing release; a conflicting one fails with
  `SdrAgent.Agents.Errors.ReleaseConflict`. See
  `SdrAgent.Agents.ModelResultRelease`.
  """
  def decide_result_release(attrs, opts) do
    actor = Keyword.get(opts, :actor)
    attrs = Map.new(attrs)

    guard(ModelResultRelease, :decide, Map.get(attrs, :model_invocation_id), actor, fn ->
      ModelResultRelease
      |> Ash.Changeset.for_create(:decide, attrs, actor: actor, context: decide_context(opts))
      |> Ash.create()
    end)
  end

  # `prelocked:` (the finalizer's `ReleaseDecision.Prelocked`, R0-07 round 5
  # contract (d)) travels under its own key and is verified by the change.
  defp decide_context(opts) do
    context = Keyword.get(opts, :context, %{})

    case Keyword.fetch(opts, :prelocked) do
      {:ok, prelocked} -> Map.put(context, :sdr_prelocked, prelocked)
      :error -> context
    end
  end

  @doc """
  AGT: the guarded calibration finish (R0-07 slice E, row R11-2) of a
  terminal generation-2 ClaudeCLI invocation of a `:proof` run with no
  Operation: decides its `:calibration` latch with `evidence: %{sha256:
  <lowercase hex>}` — the published artifact's hash, validated first by the
  calibration console — and finishes a still-running run `:succeeded` with
  `:calibration_latched` (an already-terminal run is unchanged). The only
  writer of `:calibration_latched`. Returns `{:ok, %{release:, run:}}`,
  `{:error, :calibration_evidence_conflict}` for a different hash,
  `{:error, :calibration_not_finishable}`, or `Ash.Error.Forbidden`. See
  `SdrAgent.Agents.CalibrationFinish`.
  """
  def finish_calibration(invocation, evidence, opts) do
    actor = Keyword.get(opts, :actor)

    subject_id =
      case invocation do
        %{id: id} -> id
        _malformed -> nil
      end

    guard(AgentRun, :finish_calibration, subject_id, actor, fn ->
      CalibrationFinish.run(invocation, evidence, actor)
    end)
  end

  @doc """
  The G-R0 binding for `profile_id` (packet 8.3, read-only preflight of the
  calibration console), as AGT of `tenant_id`: `{:ok, %{grant_id:,
  grant_revision:, allocation_id:, profile_id:}}`, `{:error,
  :calibration_grant_unavailable}` (zero, several or a deviating grant),
  or `Ash.Error.Forbidden`. Writes nothing.
  """
  def select_calibration_grant(tenant_id, profile_id, opts) do
    case Keyword.get(opts, :actor) do
      %SdrAgent.Actor{type: :agent_runtime, tenant_id: ^tenant_id} when is_binary(tenant_id) ->
        if ModelProfiles.real?(profile_id),
          do: Admission.calibration_grant(tenant_id, profile_id, SdrAgent.Clock.utc_now()),
          else: {:error, :calibration_grant_unavailable}

      _other ->
        {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  @doc """
  The calibration recovery action (R0-07 E4c-5; test-seam builds and the
  calibration console only): `decision` is `:unlaunched`, `{:quiescent,
  observation}` or `{:attested, attestation}`. Returns `{:ok, %{invocation:,
  attestation_event:}}`, `{:error, :calibration_not_recoverable |
  :calibration_not_quiescent | :attestation_mismatch |
  :attestation_conflict}`, or `Ash.Error.Forbidden`. See
  `SdrAgent.Agents.CalibrationRecovery`.
  """
  def recover_calibration(invocation, decision, opts) do
    actor = Keyword.get(opts, :actor)

    subject_id =
      case invocation do
        %{id: id} -> id
        _malformed -> nil
      end

    guard(ModelInvocation, :mark_unknown, subject_id, actor, fn ->
      CalibrationRecovery.run(invocation, decision, actor)
    end)
  end

  @doc "The release of an invocation in the actor's tenant: `{:ok, release | nil}`."
  def get_result_release(invocation_id, opts) do
    actor = Keyword.get(opts, :actor)

    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(model_invocation_id == ^invocation_id)
    |> Ash.read_one()
  end

  @doc "The releases of the actor's tenant, oldest decision first."
  def list_result_releases(opts) do
    actor = Keyword.get(opts, :actor)

    ModelResultRelease
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(decided_at: :asc, id: :asc)
    |> Ash.read()
  end

  @doc """
  The business read of one invocation's model output (R0-07 REQ-07-5):
  `{:ok, output}` for a generation-2 ClaudeCLI invocation only when it has a
  `:released` release, and for a generation-1 or Fake invocation as stored;
  otherwise `{:error, :result_not_released}` (`{:error, :not_found}` outside
  the actor's tenant). See `SdrAgent.Agents.ReleasedOutput`. C2* operation
  snapshot entry `:released_output` (ADR-0005 C2* item 2).
  """
  def released_output(invocation, opts) do
    OperationSnapshot.enter(:released_output, fn ->
      ReleasedOutput.fetch(invocation, Keyword.get(opts, :actor))
    end)
  end

  ## Helpers

  defp create(resource, action, attrs, opts, subject_id \\ nil) do
    actor = Keyword.get(opts, :actor)

    guard(resource, action, subject_id, actor, fn ->
      resource
      |> Ash.Changeset.for_create(action, attrs, actor: actor)
      |> Ash.create()
    end)
  end

  defp update(%resource{} = record, action, attrs, opts) do
    actor = Keyword.get(opts, :actor)
    guard(resource, action, record.id, actor, fn -> do_update(record, action, attrs, actor) end)
  end

  defp do_update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(return_notifications?: true)
    |> collect()
  end

  defp store(content, actor) when is_binary(content) do
    Payload
    |> Ash.Changeset.for_create(:store, %{content: content, content_type: "application/json"},
      actor: actor
    )
    |> Ash.create(return_notifications?: true)
    |> collect()
  end

  defp store(_content, _actor),
    do:
      {:error,
       Ash.Error.to_error_class(InvalidAttribute.exception(field: :body, message: "is required"))}

  defp put_body(attrs, _field, nil, _actor), do: {:ok, attrs}

  defp put_body(attrs, field, body, actor) do
    with {:ok, payload} <- store(body, actor), do: {:ok, Map.put(attrs, field, payload.sha256)}
  end

  # Multi-step writes run in one transaction; Ash notifications produced
  # inside it are sent only after it commits.

  # --- run settings (C4) -----------------------------------------------

  @doc """
  ADM: saves the next revision of one run setting (C4,
  `docs/product/c4/readiness.md` sections 3.8 and 12). `attrs`: `kind`,
  `content` (the atom-keyed shape of that kind), `expected_number` (the
  revision number the admin saw, 0 for none), `note`, `confirm_raised`
  (limits only: exactly the fields raised above the value in effect, any
  order).

  Returns `{:ok, revision}`, or `{:error, reason}` with nothing written:
  `Ash.Error.Forbidden` for any actor but an active human admin of the
  tenant (re-read now; the denial is audited), `{:stale_revision, latest}`
  with the latest committed number, or `{:invalid, [{field, rule}]}` keyed
  by field (`confirm_raised: :mismatch` for a raise whose confirmation is
  not exactly the raised set). No error carries a settings value.

  A stale save found under the revision lock, or a unique-key conflict with
  a concurrent save, rolls back first; the latest committed number is then
  read in a fresh statement. Called inside a caller's own transaction, a
  unique-key conflict aborts that transaction, so the Ash error is returned
  for the caller to roll back.
  """
  def create_settings_revision(attrs, opts) do
    attrs = Map.new(attrs)

    meta = %{
      resource: SettingsRevision,
      action: :create_revision,
      guarded?: true,
      subject_id: nil
    }

    case settings_actor(Keyword.get(opts, :actor)) do
      {:ok, actor} ->
        Guard.run(meta, actor, fn -> checked_settings_revision(attrs, actor) end)

      {:refuse, nil} ->
        {:error, Ash.Error.Forbidden.exception([])}

      {:refuse, operator} ->
        Guard.run(meta, operator, fn -> {:error, Ash.Error.Forbidden.exception([])} end)
    end
  end

  @doc """
  D-268: fixed profile/guide seed-history facts for the live prototype
  operator inside its caller-owned transaction. Returns only `empty?`,
  `matches?`, sorted revision `ids` and the fixed `subject_resource` name;
  never content or free-text notes. `matches?` requires exactly one root
  revision of each kind with this provenance digest's closed note.

  Refusals are closed: `:seed_failed` without a transaction or on a returned
  read error, `:not_prototype_runtime` outside prototype runtime (always in
  production), `:forbidden` for a non-live operator, `:seed_invalid` for a
  malformed digest. The owner must roll back immediately on any error.
  """
  @spec prototype_seed_settings_history(term(), SdrAgent.Actor.t()) ::
          {:ok, map()} | {:error, atom()}
  def prototype_seed_settings_history(digest, actor), do: seed_settings_history(digest, actor)

  @doc """
  D-268: invokes the existing settings `:seed_prototype` action as the
  live operator in its caller-owned transaction. `context` must contain
  exactly `sdr_seed_run_id` with a canonical UUID; no scope or kernel
  context is accepted. Existing action policies/content rules stay intact.

  Same caller refusals as `prototype_seed_settings_history/2`; malformed
  context or returned Invalid is `:seed_invalid`, other returned action
  failure is `:seed_failed`. Production always refuses with
  `:not_prototype_runtime`. Raises propagate without inspection. An action
  can itself roll the owner transaction back; the seed owner closes that
  result and never queries after failure.
  """
  @spec seed_prototype_settings_revision(map(), SdrAgent.Actor.t(), term()) ::
          {:ok, struct()} | {:error, atom()}
  def seed_prototype_settings_revision(attrs, actor, context),
    do: seed_settings_revision(attrs, actor, context)

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp seed_settings_history(digest, actor) do
      with :ok <- seed_settings_caller(actor),
           :ok <- seed_settings_digest(digest) do
        SettingsRevision
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
        |> Ash.Query.filter(
          tenant_id == ^actor.tenant_id and kind in [:offering_profile, :writing_guide]
        )
        |> Ash.Query.select([:id, :kind, :number, :note])
        |> Ash.read()
        |> case do
          {:ok, revisions} -> {:ok, seed_settings_facts(revisions, digest)}
          {:error, _error} -> {:error, :seed_failed}
        end
      end
    end

    defp seed_settings_facts(revisions, digest) do
      matches? =
        length(revisions) == 2 and
          Enum.sort(Enum.map(revisions, & &1.kind)) == [:offering_profile, :writing_guide] and
          Enum.all?(
            revisions,
            &(&1.number == 1 and &1.note == "d237 seed provenance sha256:" <> digest)
          )

      %{
        empty?: revisions == [],
        matches?: matches?,
        ids: Enum.sort(Enum.map(revisions, & &1.id)),
        subject_resource: inspect(SettingsRevision)
      }
    end

    defp seed_settings_revision(attrs, actor, context) do
      with :ok <- seed_settings_caller(actor),
           :ok <- seed_settings_context(context) do
        SettingsRevision
        |> Ash.Changeset.for_create(:seed_prototype, attrs, actor: actor, context: context)
        |> Ash.create()
        |> case do
          {:ok, revision} -> {:ok, revision}
          {:error, %Ash.Error.Invalid{}} -> {:error, :seed_invalid}
          {:error, _error} -> {:error, :seed_failed}
        end
      end
    end

    defp seed_settings_caller(actor) do
      cond do
        not Repo.in_transaction?() -> {:error, :seed_failed}
        SdrAgent.Prototype.runtime() != :prototype -> {:error, :not_prototype_runtime}
        not SdrAgent.Prototype.Authority.operator?(actor) -> {:error, :forbidden}
        true -> :ok
      end
    end

    defp seed_settings_digest(digest) do
      if is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
        do: :ok,
        else: {:error, :seed_invalid}
    end

    defp seed_settings_context(%{sdr_seed_run_id: id} = context)
         when map_size(context) == 1 and is_binary(id) do
      if Ecto.UUID.cast(id) == {:ok, id}, do: :ok, else: {:error, :seed_invalid}
    end

    defp seed_settings_context(_context), do: {:error, :seed_invalid}
  else
    defp seed_settings_history(_digest, _actor), do: {:error, :not_prototype_runtime}
    defp seed_settings_revision(_attrs, _actor, _context), do: {:error, :not_prototype_runtime}
  end

  # A human operator is re-read, so the save and its event carry the current
  # role and status (`CurrentAdmin` re-reads it again). A struct claiming
  # another tenant than its persisted row is refused, the denial audited in
  # the operator's own tenant; an unknown operator is refused unaudited (it
  # has no chain).
  defp settings_actor(%SdrAgent.Accounts.User{id: id, tenant_id: tenant_id} = user)
       when is_binary(id) do
    case Ash.get(SdrAgent.Accounts.User, id, authorize?: false) do
      {:ok, %{tenant_id: ^tenant_id} = fresh} -> {:ok, fresh}
      {:ok, fresh} -> {:refuse, fresh}
      _missing -> if is_binary(tenant_id), do: {:refuse, nil}, else: {:ok, user}
    end
  end

  defp settings_actor(actor), do: {:ok, actor}

  # The raw input shapes are checked before Ash casts anything, so no input
  # value reaches an Ash error, its message or a span status. An invalid
  # input is still refused as Forbidden (and the denial audited) for an
  # actor the action's policy refuses.
  defp checked_settings_revision(attrs, actor) do
    case RunSettings.ContentRules.input(attrs) do
      :ok ->
        save_settings_revision(attrs, actor)

      {:error, errors} ->
        if Ash.can?({SettingsRevision, :create_revision}, actor),
          do: {:error, {:invalid, errors}},
          else: {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp save_settings_revision(attrs, actor) do
    input =
      attrs
      |> Map.take([:kind, :content, :expected_number, :note])
      |> Map.put(:confirm_raised, RunSettings.ContentRules.confirm_names(attrs[:confirm_raised]))

    fn ->
      SettingsRevision
      |> Ash.Changeset.for_create(:create_revision, input, actor: actor)
      |> Ash.create()
      |> case do
        {:ok, revision} -> revision
        {:error, error} -> Repo.rollback(error)
      end
    end
    |> SdrAgent.Audit.transaction()
    |> settings_result(attrs, actor)
  end

  defp settings_result({:ok, revision}, _attrs, _actor), do: {:ok, revision}

  defp settings_result({:error, error}, attrs, actor) do
    error = Ash.Error.to_error_class(error)

    cond do
      match?(%Ash.Error.Forbidden{}, error) ->
        {:error, error}

      stale_revision?(error) and not Repo.in_transaction?() ->
        {:error, {:stale_revision, latest_settings_number(actor, attrs[:kind])}}

      stale_revision?(error) ->
        {:error, error}

      match?(%Ash.Error.Invalid{}, error) ->
        {:error, {:invalid, settings_field_errors(error)}}

      true ->
        {:error, error}
    end
  end

  defp stale_revision?(%{errors: errors}), do: Enum.any?(errors, &stale_error?/1)
  defp stale_revision?(_error), do: false

  defp stale_error?(%{field: :expected_number, vars: vars}) when is_list(vars),
    do: vars[:rule] == :stale

  defp stale_error?(%{private_vars: private}) when is_list(private),
    do: private[:constraint_type] == :unique

  defp stale_error?(_error), do: false

  defp latest_settings_number(%{tenant_id: tenant_id}, kind) when is_binary(tenant_id),
    do: SdrAgent.Agents.Changes.SettingsRevisionChain.latest_number(tenant_id, kind)

  defp latest_settings_number(_actor, _kind), do: 0

  defp settings_field_errors(%{errors: errors}) do
    errors
    |> Enum.map(fn error -> {settings_error_field(error), settings_error_rule(error)} end)
    |> Enum.uniq()
  end

  defp settings_error_field(%{field: field}) when is_atom(field) and not is_nil(field), do: field
  defp settings_error_field(%{fields: [field | _]}) when is_atom(field), do: field
  defp settings_error_field(%{argument: argument}) when is_atom(argument), do: argument
  defp settings_error_field(_error), do: :base

  defp settings_error_rule(%{vars: vars}) when is_list(vars) do
    case vars[:rule] do
      rule when is_atom(rule) and not is_nil(rule) -> rule
      _other -> :invalid
    end
  end

  defp settings_error_rule(_error), do: :invalid

  @doc """
  The settings page only (C4-R11; never called by agent code): per kind,
  the current revision or the built-in default in effect —
  `{:ok, %{kind => %{source: :revision | :code_default | :absent, revision,
  version, content_sha256, content}}}` — read as `actor` (admin, reviewer
  or auditor of the tenant; content per the field policy).
  """
  def current_settings(opts) do
    actor = Keyword.get(opts, :actor)

    with %{tenant_id: tenant_id} when is_binary(tenant_id) <- actor || {:error, :forbidden},
         {:ok, revisions} <-
           SettingsRevision
           |> Ash.Query.for_read(:read, %{}, actor: actor)
           |> Ash.Query.filter(tenant_id == ^tenant_id)
           |> Ash.Query.sort(number: :asc)
           |> Ash.read() do
      current = Map.new(revisions, &{&1.kind, &1})

      {:ok,
       Map.new(RunSettings.kinds(), fn kind -> {kind, current_slot(kind, current[kind])} end)}
    else
      {:error, error} -> {:error, error}
      _other -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp current_slot(kind, nil) do
    case RunSettings.CodeDefaults.current(kind) do
      nil ->
        %{source: :absent, revision: nil, version: nil, content_sha256: nil, content: nil}

      entry ->
        %{
          source: :code_default,
          revision: nil,
          version: entry.version,
          content_sha256: entry.content_sha256,
          content: entry.content
        }
    end
  end

  defp current_slot(kind, revision),
    do: %{
      source: :revision,
      revision: revision,
      version: nil,
      content_sha256: revision.content_sha256,
      content: Map.get(revision, kind)
    }

  @doc """
  The resolved settings of `run`'s snapshot (C4-R5, section 12): `{:ok,
  %{kind => %{source, revision_id, version, content_sha256, content}}}`
  for all five kinds — the revision's content, the built-in default's
  content by version (its pinned hash re-checked, else
  `{:error, :settings_default_unavailable}`), or the absent slot
  `%{source: :absent, revision_id: nil, version: nil, content_sha256: nil,
  content: nil}`. Never the current revisions. `{:error,
  :no_settings_snapshot}` for a run without one. Read as `actor` (the
  snapshot and the content field policy apply).
  """
  def run_settings(run, opts) do
    actor = Keyword.get(opts, :actor)

    with id when is_binary(id) <- Map.get(run, :settings_snapshot_id) || :no_snapshot,
         {:ok, snapshot} <- read_snapshot(id, run.tenant_id, actor) do
      resolve_slots(snapshot, actor)
    else
      :no_snapshot -> {:error, :no_settings_snapshot}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_slots(snapshot, actor) do
    Enum.reduce_while(RunSettings.kinds(), {:ok, %{}}, fn kind, {:ok, acc} ->
      case resolve_slot(kind, snapshot, actor) do
        {:ok, slot} -> {:cont, {:ok, Map.put(acc, kind, slot)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_snapshot(id, tenant_id, actor) do
    RunSettingsSnapshot
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: RunSettingsSnapshot)}
      other -> other
    end
  end

  defp resolve_slot(kind, snapshot, actor) do
    sha = Map.fetch!(snapshot, :"#{kind}_content_sha256")

    case Map.fetch!(snapshot, :"#{kind}_source") do
      :revision ->
        revision_slot(kind, Map.fetch!(snapshot, :"#{kind}_revision_id"), sha, snapshot, actor)

      :code_default ->
        version = Map.fetch!(snapshot, :"#{kind}_code_default_version")

        with {:ok, entry} <- RunSettings.CodeDefaults.fetch(kind, version),
             true <- entry.content_sha256 == sha do
          {:ok,
           %{
             source: :code_default,
             revision_id: nil,
             version: version,
             content_sha256: sha,
             content: entry.content
           }}
        else
          _ -> {:error, :settings_default_unavailable}
        end

      :absent ->
        {:ok,
         %{source: :absent, revision_id: nil, version: nil, content_sha256: nil, content: nil}}
    end
  end

  defp revision_slot(kind, id, sha, snapshot, actor) do
    SettingsRevision
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^snapshot.tenant_id and kind == ^kind)
    |> Ash.read_one()
    |> case do
      {:ok, %SettingsRevision{content_sha256: ^sha} = revision} ->
        {:ok,
         %{
           source: :revision,
           revision_id: revision.id,
           version: nil,
           content_sha256: sha,
           content: Map.get(revision, kind)
         }}

      {:ok, _other} ->
        {:error, :settings_revision_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  The run page's view of `run`'s settings snapshot (C4-R11, C4-R14):
  metadata only, never settings content — `{:ok, %{id, slots, limits,
  run_ceilings}}` where `slots` maps each kind to `%{source, revision_id,
  number, version}` (`number` is the revision number of a `:revision`
  slot), `limits` are the twelve limits recorded at snapshot time and
  `run_ceilings` the run's per-field ceiling before its independent budgets
  (`SdrAgent.Agents.RunSettings.ceiling/3`, the value `allowance/2` gives).
  Whether a call or fetch is allowed now is decided only at use, by the
  guarded step. `{:error, :no_settings_snapshot}` for a run without one.
  Read as `actor` through the snapshot's and revisions' read policies; an
  auditor's view must be recorded by the caller.
  """
  def run_settings_summary(run, opts) do
    actor = Keyword.get(opts, :actor)

    with id when is_binary(id) <- Map.get(run, :settings_snapshot_id) || :no_snapshot,
         {:ok, snapshot} <- read_snapshot(id, run.tenant_id, actor),
         {:ok, numbers} <- snapshot_revision_numbers(snapshot, actor) do
      limits =
        Map.new(RunSettings.Safeguards.limit_fields(), &{&1, Map.fetch!(snapshot.limits, &1)})

      {:ok,
       %{
         id: snapshot.id,
         slots: Map.new(RunSettings.kinds(), &{&1, summary_slot(&1, snapshot, numbers)}),
         limits: limits,
         run_ceilings:
           Map.new(limits, fn {field, _value} ->
             {field, RunSettings.ceiling(run, limits, field)}
           end)
       }}
    else
      :no_snapshot -> {:error, :no_settings_snapshot}
      {:error, error} -> {:error, error}
    end
  end

  defp snapshot_revision_numbers(snapshot, actor) do
    ids =
      RunSettings.kinds()
      |> Enum.map(&Map.fetch!(snapshot, :"#{&1}_revision_id"))
      |> Enum.reject(&is_nil/1)

    SettingsRevision
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id in ^ids and tenant_id == ^snapshot.tenant_id)
    |> Ash.Query.select([:id, :kind, :number])
    |> Ash.read()
    |> case do
      {:ok, revisions} when length(revisions) == length(ids) ->
        {:ok, Map.new(revisions, &{&1.id, &1.number})}

      {:ok, _missing} ->
        {:error, :settings_revision_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  defp summary_slot(kind, snapshot, numbers) do
    revision_id = Map.fetch!(snapshot, :"#{kind}_revision_id")

    %{
      source: Map.fetch!(snapshot, :"#{kind}_source"),
      revision_id: revision_id,
      number: revision_id && Map.fetch!(numbers, revision_id),
      version: Map.fetch!(snapshot, :"#{kind}_code_default_version")
    }
  end

  @doc """
  The business-content completeness pre-check of `SdrAgent.SDR.assign_lead/2`
  (C4-R8): `:ok`, or `{:error, {:settings_incomplete, kinds}}` when the
  tenant of `actor` lacks a settings kind runs of `origin` require. A plain
  read; `AgentRun :create` checks again under the chain head.
  """
  def settings_complete(origin, opts) do
    case Keyword.get(opts, :actor) do
      %{tenant_id: tenant_id} when is_binary(tenant_id) ->
        case BuildSettingsSnapshot.missing(
               origin,
               BuildSettingsSnapshot.current_revisions(tenant_id)
             ) do
          [] -> :ok
          kinds -> {:error, {:settings_incomplete, kinds}}
        end

      _other ->
        {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  # --- real-model call grants (C9) -------------------------------------

  @doc """
  OPR (D-237 prototype runtime only; interfaces r6 IF-2 "Provisioning";
  closure note r2): provisions, or replays, the one `d237-funding/1` grant.
  `attrs`: `worksheet:` (the budget worksheet bytes) and `worksheet_sha256:`
  (its hex digest); `opts`: `actor:` and `evidence_root:` (explicit, no
  default: D2).

  1. Only the resolved operator (`OperatorAction :provision`, live) passes;
     any other caller is `Forbidden` before any input is read, audited once
     through `SdrAgent.Audit.Guard.refuse/2` for a well-formed actor.
  2. A call inside an already-open transaction is
     `{:error, :binding_mismatch}` (a nested transaction is not a
     savepoint; the provision task never nests). No `evidence_root` is
     `{:error, :budget_unbounded}`; a digest that does not match the bytes
     is `{:error, :worksheet_invalid}`.
  3. In one `SdrAgent.Audit.transaction/1`, under the binding-row lock:
     when this binding's grant exists by its original provisioned event,
     it is returned only if it is still active with the exact entry terms
     and allocation and the original digest equals this one (no evidence
     is read, nothing is written); any other existing, untrusted or
     ambiguous provenance is `{:error, :grant_exists}`. Otherwise
     `ModelCallGrant :provision_prototype` runs (guarded), which re-checks
     everything itself.

  Refusals of the action are returned as plain reasons: `:grant_exists`,
  `:worksheet_invalid`, `:budget_unbounded`, `:budget_below_ceiling`,
  `:binding_mismatch`. Outside prototype runtime, and in a build without
  the prototype authority, every caller is refused.
  """
  @spec provision_prototype_grant(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def provision_prototype_grant(attrs, opts), do: provision_or_refuse(attrs, opts)

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Agents.Errors.ProvisionRefused
    alias SdrAgent.Prototype.Checks.OperatorAction
    alias SdrAgent.Prototype.Provisioning

    defp provision_or_refuse(attrs, opts) do
      actor = Keyword.get(opts, :actor)

      if OperatorAction.match?(actor, nil, action: :provision),
        do: provision_top_level(attrs, actor, Keyword.get(opts, :evidence_root)),
        else: Guard.refuse(@provision_meta, actor)
    end

    # Precedence: a non-operator is Forbidden (and audited) first; then an
    # already-open caller transaction is refused with :binding_mismatch
    # before any write (a nested Audit or Repo transaction is not a
    # savepoint; the provision task, the one caller, never nests: Codex
    # 17a870c0); then the explicit evidence root and the digest.
    defp provision_top_level(attrs, actor, root) do
      if Repo.in_transaction?(),
        do: {:error, :binding_mismatch},
        else: provision_as_operator(attrs, actor, root)
    end

    defp provision_as_operator(_attrs, _actor, root) when not is_binary(root),
      do: {:error, :budget_unbounded}

    defp provision_as_operator(%{worksheet: bytes, worksheet_sha256: digest}, actor, root)
         when is_binary(bytes) and is_binary(digest) do
      if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest do
        fn -> replay_or_mint(bytes, digest, root, actor) end
        |> SdrAgent.Audit.transaction()
        |> provision_result()
      else
        {:error, :worksheet_invalid}
      end
    end

    defp provision_as_operator(_attrs, _actor, _root), do: {:error, :worksheet_invalid}

    defp replay_or_mint(bytes, digest, root, actor) do
      with {:ok, snapshot} <- SdrAgent.Prototype.binding(),
           :ok <- Provisioning.lock_binding(snapshot) do
        case Provisioning.lookup(snapshot) do
          {:one, grant_id, event} -> replay(snapshot, grant_id, event, digest)
          :untrusted -> Repo.rollback(:grant_exists)
          :none -> mint(bytes, root, actor)
        end
      else
        _mismatch -> Repo.rollback(:binding_mismatch)
      end
    end

    # An identical replay of the unchanged original: no evidence read, no write.
    defp replay(snapshot, grant_id, event, digest) do
      with {:ok, grant, allocations} <- Provisioning.lock_grant(snapshot, grant_id),
           true <- Provisioning.unchanged?(grant, allocations),
           true <- Provisioning.digest(event) == digest do
        grant
      else
        _changed_or_different -> Repo.rollback(:grant_exists)
      end
    end

    defp mint(bytes, root, actor) do
      case GuardedCall.create(
             ModelCallGrant,
             :provision_prototype,
             %{worksheet: bytes, evidence_root: root},
             actor: actor,
             guarded?: true
           ) do
        {:ok, grant} -> grant
        {:error, error} -> Repo.rollback(refusal(error))
      end
    end

    defp refusal(%Ash.Error.Invalid{errors: errors} = error) do
      Enum.find_value(errors, error, fn
        %ProvisionRefused{reason: reason} -> reason
        _other -> nil
      end)
    end

    defp refusal(error), do: error

    # Ash rolls the enclosing transaction back with the failed changeset;
    # its errors carry the action's closed refusal reason.
    defp provision_result({:error, %Ash.Changeset{errors: errors}}),
      do: {:error, refusal(Ash.Error.to_error_class(errors))}

    defp provision_result(result), do: result
  else
    # No prototype authority in this build (production): every caller is
    # refused before any input is read.
    defp provision_or_refuse(_attrs, opts),
      do: Guard.refuse(@provision_meta, Keyword.get(opts, :actor))
  end

  @doc """
  ADM: creates a grant and its `allocations` (a list of maps with `:key`,
  `:applies_to`, `:attempts` and optional `:profile_id`, `:available_from`,
  `:available_until`) as one validated bundle. Returns the grant with its
  allocations loaded.
  """
  def create_grant(attrs, opts) do
    grant_transaction(opts, fn opts ->
      GuardedCall.create(ModelCallGrant, :create, Map.new(attrs), opts)
    end)
  end

  @doc """
  ADM: changes a grant's terms (any of `name`, `purpose`, `profile_ids`,
  `total_attempts`, `per_utc_day_attempts`, `starts_at`, `expires_at`) and
  its `allocations`, matched by `{key, profile_id}` (a match is updated, a
  new pair is created, none is deleted), validated as one final state.
  Requires `expected_revision`.
  """
  def update_grant_terms(%ModelCallGrant{} = grant, attrs, opts) do
    grant_transaction(opts, fn opts ->
      GuardedCall.update(grant, :update_terms, Map.new(attrs), opts)
    end)
  end

  @doc "ADM: revokes a grant (terminal). Requires `expected_revision`."
  def revoke_grant(%ModelCallGrant{} = grant, attrs, opts) do
    grant_transaction(opts, fn opts ->
      GuardedCall.update(grant, :revoke, Map.take(Map.new(attrs), [:expected_revision]), opts)
    end)
  end

  @doc """
  ADM: releases the allocation `key` (with optional `profile_id`) for use
  before its `available_from`. Requires the grant's `expected_revision`.
  """
  def release_allocation(%ModelCallGrant{} = grant, attrs, opts) do
    attrs = Map.take(Map.new(attrs), [:expected_revision, :key, :profile_id])

    grant_transaction(opts, fn opts ->
      GuardedCall.update(grant, :release_allocation, attrs, opts)
    end)
  end

  @doc "ADM, AUD, AGT: the tenant's grants with allocations, oldest first."
  def list_grants(opts) do
    actor = Keyword.get(opts, :actor)

    ModelCallGrant
    |> tenant_scope(actor)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.load(:allocations)
    |> Ash.read(actor: actor)
  end

  @doc "ADM, AUD, AGT: one grant with allocations."
  def get_grant(id, opts) do
    actor = Keyword.get(opts, :actor)

    ModelCallGrant
    |> tenant_scope(actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(:allocations)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: ModelCallGrant)}
      other -> other
    end
  end

  @doc """
  ADM, AUD, AGT: the attempts consumed by the grants `grant_ids` that the
  actor can read — `{:ok, %{grant_id => %{consumed:, today:, allocations:
  %{allocation_id => consumed}}}}`. Consumption is derived from the
  ModelInvocations charged to the grant and allocation at reservation
  (C9-02; never stored, never refunded); `today` counts the current UTC day
  by `reserved_at` (`SdrAgent.Clock`), as the per-day limit does. Grants the
  actor cannot read (another tenant, or a reviewer) are absent.
  """
  def grant_usage([], _opts), do: {:ok, %{}}

  def grant_usage(grant_ids, opts) when is_list(grant_ids) do
    actor = Keyword.get(opts, :actor)

    with {:ok, grants} <- readable_grants(grant_ids, actor),
         {:ok, charged} <- charged_invocations(Enum.map(grants, & &1.id), actor) do
      today = DateTime.to_date(SdrAgent.Clock.utc_now())
      by_grant = Enum.group_by(charged, & &1.grant_id)

      {:ok,
       Map.new(grants, fn grant ->
         {grant.id, usage(grant, Map.get(by_grant, grant.id, []), today)}
       end)}
    end
  end

  defp readable_grants(grant_ids, actor) do
    ModelCallGrant
    |> tenant_scope(actor)
    |> Ash.Query.filter(id in ^grant_ids)
    |> Ash.Query.load(:allocations)
    |> Ash.read(actor: actor)
  end

  defp charged_invocations([], _actor), do: {:ok, []}

  defp charged_invocations(grant_ids, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.filter(grant_id in ^grant_ids)
    |> Ash.Query.select([:grant_id, :allocation_id, :reserved_at])
    |> Ash.read()
  end

  defp usage(grant, charged, today) do
    counts = Enum.frequencies_by(charged, & &1.allocation_id)

    %{
      consumed: length(charged),
      today: Enum.count(charged, &(DateTime.to_date(&1.reserved_at) == today)),
      allocations: Map.new(grant.allocations, &{&1.id, Map.get(counts, &1.id, 0)})
    }
  end

  # --- model profile switches (C2-02a) ---------------------------------

  @doc """
  ADM: requests a switch of the tenant's desired model profile —
  `%{to_profile_id, expected_revision, server_generation}`. Creates the
  setting on the first request. See `SdrAgent.Agents.ProfileSwitches`.
  """
  def request_profile_switch(attrs, opts), do: ProfileSwitches.request(attrs, opts)

  @doc "MRT: pending → completed, applying the switch to the setting (`%{server_generation}`)."
  def complete_profile_switch(switch, attrs, opts),
    do: ProfileSwitches.transition(:complete, switch, attrs, opts)

  @doc "MRT: pending → failed (`%{server_generation, failure_reason}`); the setting is unchanged."
  def fail_profile_switch(switch, attrs, opts),
    do: ProfileSwitches.transition(:fail, switch, attrs, opts)

  @doc "MRT: pending → blocked (`%{server_generation, failure_reason}`); the setting is unchanged."
  def block_profile_switch(switch, attrs, opts),
    do: ProfileSwitches.transition(:block, switch, attrs, opts)

  @doc "ADM, AUD (audited), AGT: the tenant's setting, or `{:ok, nil}` before the first one."
  def get_profile_setting(opts), do: ProfileSwitches.get_setting(opts)

  @doc """
  ADM (C2-02b2β): the read-only facts a blocked switch's resolution is
  attested on — the switch, the coordinator's boot, its latest start and
  hold, the covered starts with their recorded identity, and the observed
  lease kind. See `SdrAgent.Agents.ProfileSwitches.blocked_facts/2`.
  """
  def blocked_switch_facts(switch, opts), do: ProfileSwitches.blocked_facts(switch, opts)

  @doc """
  ADM (C2-02b2β): resolves a blocked switch to `:failed` under a typed owner
  attestation (`%{attestation_id, switch_id, attested_start_id,
  attested_generation, attested_lease_kind, outcome: :failed,
  confirmation: "STOPPED " <> switch_id}`), executed by the registered
  coordinator within a 15 s pre-dispatch deadline. A commit does not mean
  the server is ready. See `SdrAgent.Agents.ProfileSwitches.resolve_blocked/3`.
  """
  def resolve_blocked_switch(switch, attestation, opts),
    do: ProfileSwitches.resolve_blocked(switch, attestation, opts)

  # --- model server starts (C2-02b2α) -----------------------------------

  @doc """
  MRT, in the registered coordinator only: allocates the tenant's next
  model server start — `%{boot_id, profile_id, reason, switch_id?}`. See
  `SdrAgent.Agents.ServerStarts`.
  """
  def allocate_server_start(attrs, opts), do: ServerStarts.allocate(attrs, opts)

  @doc """
  MRT, in the registered coordinator only: moves the tenant's latest start
  of this boot to `:started`, `:ready` or `:failed`.
  """
  def mark_server_start(start, status, attrs, opts),
    do: ServerStarts.mark(start, status, attrs, opts)

  @doc "ADM, AUD (audited), AGT: the tenant's model server starts, by generation."
  def list_server_starts(opts), do: ServerStarts.list(opts)

  @doc "ADM, AUD (audited), AGT: the tenant's switches, newest first."
  def list_profile_switches(opts), do: ProfileSwitches.list_switches(opts)

  # One guarded transaction per grant change. A human actor is re-read
  # first, so the change and its audit events carry the operator's current
  # role (the CurrentAdmin check re-reads it again). A failing Ash action may
  # roll the transaction back itself with its changeset; either way the
  # caller gets an Ash error class.
  defp grant_transaction(opts, fun) do
    opts =
      opts |> Keyword.update(:actor, nil, &current_operator/1) |> Keyword.put(:guarded?, true)

    fn ->
      case fun.(opts) do
        {:ok, grant} -> unwrap_load(grant)
        {:error, error} -> Repo.rollback(error)
      end
    end
    |> SdrAgent.Audit.transaction()
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Ash.Error.to_error_class(error)}
    end
  end

  defp unwrap_load(grant) do
    case load_grant(grant) do
      {:ok, grant} -> grant
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp current_operator(%SdrAgent.Accounts.User{id: id} = user) do
    case Ash.get(SdrAgent.Accounts.User, id, authorize?: false) do
      {:ok, fresh} -> fresh
      _ -> user
    end
  end

  defp current_operator(actor), do: actor

  defp load_grant(grant), do: Ash.load(grant, :allocations, authorize?: false)

  # As `transact/1`, inside `SdrAgent.Audit.transaction/1` (guarded calls may
  # run in it): `fun` returns `{:ok, value}` to commit or `{:error, error}`
  # to roll back.
  defp audit_transact(fun) do
    Process.put(@notifications, [])

    result =
      SdrAgent.Audit.transaction(fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, error} -> Repo.rollback(error)
        end
      end)

    notifications = Process.delete(@notifications) || []
    if match?({:ok, _}, result), do: Ash.Notifier.notify(notifications)

    case result do
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      other -> other
    end
  end

  defp transact(fun) do
    Process.put(@notifications, [])
    result = Kernel.in_transaction(fun)
    notifications = Process.delete(@notifications) || []
    if match?({:ok, _}, result), do: Ash.Notifier.notify(notifications)
    result
  end

  defp collect({:ok, record, notifications}) do
    case Process.get(@notifications) do
      nil -> Ash.Notifier.notify(notifications)
      pending -> Process.put(@notifications, pending ++ notifications)
    end

    {:ok, record}
  end

  defp collect(other), do: other

  # Reads are scoped to the actor's tenant; an operator without a tenant
  # reads nothing (fail closed). Tenantless system actors (KRN) are unscoped.
  defp tenant_scope(query, %{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: Ash.Query.filter(query, tenant_id == ^tenant_id)

  defp tenant_scope(query, %SdrAgent.Accounts.User{}), do: Ash.Query.filter(query, false)
  defp tenant_scope(query, _actor), do: query

  defp guard(resource, action, subject_id, actor, fun) do
    Guard.run(%{resource: resource, action: action, subject_id: subject_id}, actor, fun)
  end
end

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
      a different hash is refused), `retire_definition/2`;
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
      settles run usage in the same transaction), `list_model_invocations/2`;
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
    * real-model call grants (C9) — `create_grant/2`,
      `update_grant_terms/3`, `revoke_grant/3`, `release_allocation/3`
      (each an active human admin only, in one transaction, refusing a stale
      `expected_revision`), `list_grants/1`, `get_grant/2`, and
      `grant_usage/2` (the attempts consumed, derived from the charged
      ModelInvocations).
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query
  require Logger

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.NotFound
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
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

  @doc "running → failed with `status_reason` and redacted `failure_reason` (AGT)."
  def fail_run(run, attrs, opts), do: update(run, :fail, attrs, opts)

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
  """
  def reserve_model_invocation(run, attrs, opts) do
    actor = Keyword.get(opts, :actor)

    ModelInvocation
    |> guard(:reserve, run.id, actor, fn -> reserve_normalized(run, attrs, actor) end)
    |> case do
      # The reservation rolled back; the refusal is committed on its own.
      {:error, %Admission.Refusal{} = refusal} ->
        with {:ok, refused} <- Admission.record_refusal(refusal), do: {:error, refused}

      result ->
        result
    end
  end

  defp reserve_normalized(run, attrs, actor) do
    with {:ok, attrs} <- normalize_reserve(attrs) do
      {request, attrs} = Map.pop(attrs, :request)
      transact(fn -> do_reserve_model_invocation(run, attrs, request, actor) end)
    end
  end

  # A ClaudeCLI call with a reviewed real profile goes through admission
  # (lock order: run → candidate grants → their allocations → chain head; see
  # `SdrAgent.Agents.Admission`); the admitted charge reaches :reserve only
  # through `AdmissionContext`. Any other call keeps the S6 order (run →
  # chain head); the Fake records its own profile, and any other profile is
  # left to the :reserve validation to refuse.
  defp do_reserve_model_invocation(run, %{provider: :claude_cli} = attrs, request, actor) do
    if ModelProfiles.real?(Map.get(attrs, :profile_id)),
      do: reserve_admitted(run, attrs, request, actor),
      else: reserve(run, attrs, request, actor, %{})
  end

  defp do_reserve_model_invocation(run, %{provider: :fake} = attrs, request, actor),
    do: reserve(run, Map.put(attrs, :profile_id, :fake), request, actor, %{})

  defp do_reserve_model_invocation(run, attrs, request, actor),
    do: reserve(run, attrs, request, actor, %{})

  # The admission instant is read only once every lock is held, and is used
  # for the daily limit, eligibility, the grant's UTC day and `reserved_at`.
  defp reserve_admitted(run, attrs, request, actor) do
    with {:ok, locked} <- lock_run(run.id, actor),
         {:ok, candidates} <- Admission.lock_candidates(locked, attrs.profile_id),
         {:ok, _head} <- Kernel.lock_head(locked.tenant_id),
         now = SdrAgent.Clock.utc_now(),
         {:ok, run} <- do_update(run, :reserve_model_call, %{}, actor),
         :ok <- check_daily_limit(run.tenant_id, now),
         {:ok, charge} <- Admission.admit(locked, attrs, now, candidates) do
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
  is `Ash.Error.Forbidden`, audited as `authz.denied`). Lock order: the run
  row, then the invocation row (`FOR UPDATE`, both re-read in the actor's
  tenant), then the charged grant and allocation `FOR SHARE`
  (`Admission.lock_charge/1`, the reservation's order), then the chain head
  explicitly; only then is `now` read and are the terms read. Grant
  editors lock grant → allocations → head and never a run or invocation, so
  either an edit commits first (the launch is refused) or the launch does
  (it proceeds; a later revocation does not stop a launched call).

    * **Identity and state refusals** change nothing and return `{:error,
      reason}`: `:invocation_not_found` (missing, malformed or another
      tenant's id), `:invocation_not_claude_cli`, `:invocation_not_reserved`
      (a replayed sent, in-flight or terminal row). Each is then recorded
      as a `model.launch.refused` event of the actor's tenant only.
    * **Eligibility refusals** of an owned, reserved row
      (`Admission.launch_check/4`: the locked run still `:running`,
      generation, profile, grant status and window, grant profiles,
      allocation grant, profile restriction, usage bucket, availability —
      never room, which was charged at reservation) move it reserved →
      failed (never sent) and open a critical `provider_error` Failure about
      the invocation, committed together; `{:error,
      :run_not_running_at_launch | :legacy_invocation_without_grant |
      :profile_mismatch_at_launch | :grant_ineligible_at_launch}`. A stopped
      run's refusal opens no Failure: the stop is already its cause.
    * **Success** marks it sent: `{:ok, invocation}`.
  """
  def admit_launch(invocation_id, effective_profile, opts) do
    actor = Keyword.get(opts, :actor)

    meta = %{
      resource: ModelInvocation,
      action: :admit_launch,
      guarded?: true,
      subject_id: uuid(invocation_id)
    }

    Guard.run(meta, actor, fn -> launch(invocation_id, effective_profile, actor) end)
  end

  defp launch(id, profile, %SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant} = actor)
       when is_binary(tenant) do
    case audit_transact(fn -> launch_locked(id, profile, actor) end) do
      {:ok, {:sent, sent}} ->
        {:ok, sent}

      {:ok, {:refused, reason}} ->
        {:error, reason}

      {:error, {:launch_refused, reason, own_id}} ->
        record_launch_refusal(reason, own_id, id, profile, actor)
        {:error, reason}

      {:error, error} ->
        {:error, error}
    end
  end

  defp launch(_id, _profile, _actor), do: {:error, Ash.Error.Forbidden.exception([])}

  defp launch_locked(id, profile, actor) do
    with {:ok, target} <- launch_target(id, actor),
         {:ok, run} <- lock_tenant_run(target.agent_run_id, actor),
         {:ok, invocation} <- lock_invocation(target.id, actor),
         :ok <- launch_state(invocation),
         :ok <- Admission.lock_charge(invocation),
         {:ok, _head} <- Kernel.lock_head(actor.tenant_id) do
      # The launch instant is read only once every lock is held.
      run
      |> Admission.launch_check(invocation, profile, SdrAgent.Clock.utc_now())
      |> admit_or_refuse(invocation, profile, actor)
    end
  end

  defp admit_or_refuse(:ok, invocation, _profile, actor) do
    with {:ok, sent} <- do_update(invocation, :mark_sent, %{}, actor), do: {:ok, {:sent, sent}}
  end

  defp admit_or_refuse({:error, reason, check}, invocation, profile, actor),
    do: refuse_launch(invocation, reason, check, profile, actor)

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

  defp refuse_launch(invocation, reason, check, profile, actor) do
    error = %{
      "kind" => "launch_refused",
      "reason" => Atom.to_string(reason),
      "check" => Atom.to_string(check)
    }

    failure = %{
      subject_resource: inspect(ModelInvocation),
      subject_id: invocation.id,
      class: :provider_error,
      severity: :critical,
      retryable: false,
      message:
        "model call refused at launch: #{reason} (#{check}); the reserved call was failed " <>
          "and never sent",
      detail:
        SdrAgent.Audit.Canonical.encode!(%{
          "kind" => "model_launch_refused",
          "reason" => Atom.to_string(reason),
          "check" => Atom.to_string(check),
          "model_invocation_id" => invocation.id,
          "grant_id" => invocation.grant_id,
          "reserved_profile" => profile_name(invocation.profile_id),
          "effective_profile" => profile_name(profile)
        })
    }

    with {:ok, _failed} <- do_update(invocation, :fail, %{error: error}, actor),
         {:ok, _failure} <- launch_attention(reason, failure, actor) do
      {:ok, {:refused, reason}}
    end
  end

  # A run stopped while its call was queued already has its own cause (its
  # stop's Failure, or an operator's cancel or a success, which need none):
  # the refused call is failed, but no second attention item is opened.
  defp launch_attention(:run_not_running_at_launch, _failure, _actor), do: {:ok, :none}

  defp launch_attention(_reason, failure, actor),
    do: SdrAgent.Operations.open_failure(failure, actor: actor)

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

  # --- real-model call grants (C9) -------------------------------------

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

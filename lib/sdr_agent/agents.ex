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
      `retry_run/2`, `reserve_model_call/2`, `get_run/2`,
      `find_run_by_operation/2`, `active_runs_for_lead/2`, `list_runs/1`;
    * model calls — `reserve_model_invocation/3` (reserves the run budget,
      enforces the persisted daily limit, stores the request Payload and
      numbers the call, in one transaction), `daily_model_call_limit/0`,
      `daily_model_calls/1`,
      `mark_model_invocation_sent/2`, `complete_model_invocation/3`,
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
      Payload read). Reconciliation itself: `SdrAgent.Agents.Witness`.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.NotFound
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ToolInvocation
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Audit.Checks.ReconciliationScope
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload

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

  @doc "Creates a new run retrying a failed, budget-exhausted or cancelled one (ADM, REV)."
  def retry_run(run, opts), do: create(AgentRun, :retry, %{run_id: run.id}, opts, run.id)

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
    {request, attrs} = Map.pop(Map.new(attrs), :request)

    guard(ModelInvocation, :reserve, run.id, actor, fn ->
      transact(fn -> do_reserve_model_invocation(run, attrs, request, actor) end)
    end)
  end

  defp do_reserve_model_invocation(run, attrs, request, actor) do
    with {:ok, run} <- do_update(run, :reserve_model_call, %{}, actor),
         :ok <- check_daily_limit(run.tenant_id),
         {:ok, payload} <- store(request, actor) do
      attrs =
        Map.merge(attrs, %{
          agent_run_id: run.id,
          sequence_in_run: run.budget.model_calls_reserved,
          request_sha256: payload.sha256
        })

      ModelInvocation
      |> Ash.Changeset.for_create(:reserve, attrs, actor: actor)
      |> Ash.create(return_notifications?: true)
      |> collect()
    end
  end

  @doc "The effective daily model-call limit: `min(config, 200)` (ADR-0004)."
  def daily_model_call_limit do
    case Application.get_env(:sdr_agent, :daily_model_call_limit) do
      limit when is_integer(limit) and limit >= 0 ->
        Elixir.Kernel.min(limit, @daily_model_call_limit)

      _ ->
        @daily_model_call_limit
    end
  end

  @doc "ModelInvocations of `tenant_id` reserved in the current UTC day (`SdrAgent.Clock`)."
  def daily_model_calls(tenant_id) do
    today = DateTime.to_date(SdrAgent.Clock.utc_now())
    from = DateTime.new!(today, ~T[00:00:00.000000], "Etc/UTC")
    until = DateTime.add(from, 1, :day)

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and reserved_at >= ^from and reserved_at < ^until)
    |> Ash.count!()
  end

  # Runs inside the reservation transaction (see reserve_model_invocation/3).
  defp check_daily_limit(tenant_id) do
    with {:ok, _head} <- Kernel.lock_head(tenant_id) do
      if daily_model_calls(tenant_id) < daily_model_call_limit(),
        do: :ok,
        else: {:error, {:budget_exhausted, :daily}}
    end
  end

  @doc "reserved → sent (AGT)."
  def mark_model_invocation_sent(invocation, opts),
    do: update(invocation, :mark_sent, %{}, opts)

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

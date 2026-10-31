defmodule SdrAgent.Operations do
  @moduledoc """
  Operations bounded context (S2): durable background work as operators see
  it, and the failures that need a human.

  Resources (S7): `Operation` (the domain view of one Oban job) and
  `Failure` (a recorded error with class, severity, retryability and
  resolution) and `WebhookEvent` (S9: every inbound webhook request, verified
  and deduplicated before any effect; written only by the webhook ingestor
  through `SdrAgent.Outreach.Webhooks`). `IntegrationCredential` (S6) is not
  built yet. The D-237 prototype binding and delegations, and S-B1's
  append-only relocation chain (`SdrAgent.Prototype.Relocation`,
  `SdrAgent.Prototype.RelocationEvent`; ADR-0024 decision 1), are
  kernel-only resources here, as is S-B2's `SdrAgent.Operations.MacWorker`
  (an off-host executor; owner-run enrolment and control).
  `HostedOwner` (S-B5) binds a reviewer User to
  the current activated relocation; this domain orchestrates enrollment,
  single-use link exchange and terminal disable via narrow scoped Accounts
  actions, never an Accounts dependency on Operations persistence.
  Operations sits above Audit and Accounts (FKs to tenants and users)
  and below Agents, Sales, Research and Outreach, which open Failures here in
  the same transaction as the state change that causes them (S2 "Operator
  attention"): AgentRun failed / budget exhausted / system-cancelled, Lead
  blocked, Operation failed or discarded, a drifted model-provider
  attestation.

  Public API (operator functions take `actor:`; writes run through
  `SdrAgent.Audit.Guard`, so refused auditor mutations are audited):

    * operations — `create_operation/2`, `start_operation/2`,
      `succeed_operation/2`, `fail_operation/3` (opens or links a Failure and
      discards at max attempts, one transaction), `retry_operation/2`,
      `cancel_operation/2`, `get_operation/2`, `find_operation/2`,
      `list_operations/1`;
    * failures — `open_failure/2` (system actors), `acknowledge_failure/2`
      and `resolve_failure/3` (ADM, REV; system actors resolve with a system
      note), `get_failure/2`;
    * `list_attention/1` — the single operator-attention query: Failures in
      `open` or `acknowledged`, newest first (Dashboard and Operations views;
      ADM, REV, AUR, AUD);
    * `list_failed_webhooks/1` — `failed` WebhookEvents, newest first (the
      operator webhook retry, S13b: `SdrAgent.Outreach.retry_webhook/2`);
    * `enrol_hosted_owner/2` — owner console, marked ordinary-runtime
      kernel only; `consume_hosted_owner_link/1` — signed stored enrollment
      token, no actor impersonation; `disable_hosted_owner/2` — console or
      exact live owner self, revoking every token in the same transaction.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query

  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation

  resources do
    resource SdrAgent.Operations.Operation
    resource SdrAgent.Operations.Failure
    resource SdrAgent.Operations.WebhookEvent
    # D-237 (interfaces r6 IF-2, IF-3): the prototype binding and delegations.
    resource SdrAgent.Operations.PrototypeDatabaseBinding
    resource SdrAgent.Operations.PrototypeDelegation
    # ADR-0024 decision 1 (S-B1): the append-only relocation chain.
    resource SdrAgent.Prototype.Relocation
    resource SdrAgent.Prototype.RelocationEvent
    # S-B2: the off-host executor of remote ClaudeCLI calls.
    resource SdrAgent.Operations.MacWorker
    resource SdrAgent.Operations.HostedOwner
  end

  @doc "Console-only enrollment of one reviewer bound to the live activated relocation."
  def enrol_hosted_owner(attrs, opts) do
    Guard.run(
      %{resource: SdrAgent.Operations.HostedOwner, action: :enrol, guarded?: true},
      Keyword.get(opts, :actor),
      fn -> SdrAgent.Operations.HostedOwners.enrol(attrs, opts) end
    )
  end

  @doc "Exchange one signed, stored, 15-minute enrollment link for a normal user session."
  def consume_hosted_owner_link(token), do: SdrAgent.Operations.HostedOwners.consume_link(token)

  @doc "Whether the User is admissible to this runtime's website, with fresh hosted authority."
  def hosted_web_principal?(user), do: SdrAgent.Operations.HostedOwners.web_principal?(user)

  @doc """
  W2: whether the binding has a fresh live hosted owner (prototype runtime;
  always `false` in an ordinary production build). Read-only, no row locks.
  """
  def hosted_owner_live?(tenant_id, binding_id),
    do: SdrAgent.Operations.HostedOwners.binding_owner_live?(tenant_id, binding_id)

  @doc "Terminal owner disable, coupled to disabling the reviewer and revoking every token."
  def disable_hosted_owner(id, opts) do
    Guard.run(
      %{
        resource: SdrAgent.Operations.HostedOwner,
        action: :disable,
        subject_id: id,
        guarded?: true
      },
      Keyword.get(opts, :actor),
      fn -> SdrAgent.Operations.HostedOwners.disable(id, opts) end
    )
  end

  ## Operations

  @doc "Enroll one current-binding Mac worker as the fresh hosted owner; token is returned once."
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    def enrol_mac_worker(attrs, opts) do
      attrs = Map.new(attrs)

      case SdrAgent.Prototype.binding() do
        {:ok, binding} ->
          attrs = Map.put_new(attrs, :binding_id, binding.id)
          GuardedCall.create(SdrAgent.Operations.MacWorker, :enrol, attrs, opts)

        _refused ->
          {:error, Ash.Error.Forbidden.exception([])}
      end
    end
  else
    def enrol_mac_worker(_attrs, _opts), do: {:error, Ash.Error.Forbidden.exception([])}
  end

  @doc "Explicit owner-only worker metadata; default resource reads remain private."
  def list_mac_workers(opts) do
    SdrAgent.Operations.MacWorker
    |> GuardedCall.read_query(Keyword.put(opts, :action, :owner_read))
    |> Ash.Query.sort(enrolled_at: :asc, id: :asc)
    |> Ash.read()
  end

  @doc "Open or pause intake, revalidating the exact locked worker and fresh owner."
  def set_mac_worker_intake(%SdrAgent.Operations.MacWorker{} = worker, intake, opts),
    do: GuardedCall.update(worker, :set_intake, %{intake: intake}, opts)

  @doc "Terminal worker disable; disabled workers can never be resumed."
  def disable_mac_worker(%SdrAgent.Operations.MacWorker{} = worker, opts),
    do: GuardedCall.update(worker, :disable, %{}, opts)

  @doc "Creates an `enqueued` operation (the system actor owning its `kind`)."
  def create_operation(attrs, opts), do: GuardedCall.create(Operation, :create, attrs, opts)

  @doc "enqueued → running; counts the attempt."
  def start_operation(operation, opts), do: GuardedCall.update(operation, :start, %{}, opts)

  @doc "running → succeeded."
  def succeed_operation(operation, opts), do: GuardedCall.update(operation, :succeed, %{}, opts)

  @doc "failed → running (bounded retry; the kind's system actor or ADM)."
  def retry_operation(operation, opts), do: GuardedCall.update(operation, :retry, %{}, opts)

  @doc "enqueued | failed → cancelled (ADM or the kind's system actor)."
  def cancel_operation(operation, opts), do: GuardedCall.update(operation, :cancel, %{}, opts)

  @doc """
  running → failed, opening a Failure (`failure:` map with `class`,
  `severity`, `message`, optional `retryable`, `detail`) or linking an
  existing one (`failure_id:`); when the attempts reach `max_attempts` the
  operation is also discarded — one transaction.
  """
  def fail_operation(operation, attrs, opts) do
    actor = Keyword.get(opts, :actor)
    meta = %{resource: Operation, action: :fail, subject_id: operation.id}

    Guard.run(meta, actor, fn ->
      Kernel.in_transaction(fn -> fail_and_maybe_discard(operation, Map.new(attrs), actor) end)
    end)
  end

  defp fail_and_maybe_discard(operation, attrs, actor) do
    case do_update(operation, :fail, attrs, actor) do
      {:ok, %{attempts: attempts, max_attempts: max} = failed} when attempts >= max ->
        do_update(failed, :discard, %{}, actor)

      other ->
        other
    end
  end

  @doc "Reads one operation by id."
  def get_operation(id, opts), do: GuardedCall.get(Operation, id, opts)

  @doc "Operations of the actor's tenant, newest first (S10 Operations view; ADM, REV, AUR, system readers)."
  def list_operations(opts) do
    Operation
    |> GuardedCall.read_query(opts)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read()
  end

  @doc "Failed WebhookEvents of the actor's tenant, newest first (S13b; ADM, REV, AUR, AUD)."
  def list_failed_webhooks(opts) do
    SdrAgent.Operations.WebhookEvent
    |> GuardedCall.read_query(opts)
    |> Ash.Query.filter(processing_status == :failed)
    |> Ash.Query.sort(received_at: :desc, id: :desc)
    |> Ash.read()
  end

  @doc "Finds the operation of an Oban job (`oban_job_id`), or `{:ok, nil}`."
  def find_operation(oban_job_id, opts) do
    Operation
    |> GuardedCall.read_query(opts)
    |> Ash.Query.filter(oban_job_id == ^oban_job_id)
    |> Ash.read_one()
  end

  ## Failures

  @doc "Opens a Failure (system actors). `message` is redacted; `detail` goes to a Payload."
  def open_failure(attrs, opts), do: GuardedCall.create(Failure, :open, attrs, opts)

  @doc "open → acknowledged (ADM, REV)."
  def acknowledge_failure(failure, opts), do: GuardedCall.update(failure, :acknowledge, %{}, opts)

  @doc "open | acknowledged → resolved with a required `resolution_note`."
  def resolve_failure(failure, attrs, opts),
    do: GuardedCall.update(failure, :resolve, Map.new(attrs), opts)

  @doc "Reads one failure by id."
  def get_failure(id, opts), do: GuardedCall.get(Failure, id, opts)

  @doc """
  The operator-attention queue: Failures in `open` or `acknowledged`, newest
  first, with severity, class, subject ref, message, `occurred_at` and
  `acknowledged_at`.
  """
  def list_attention(opts) do
    opts
    |> Keyword.put(:action, :attention)
    |> then(&GuardedCall.read_query(Failure, &1))
    |> Ash.read()
  end

  @doc """
  Exact scalar Home total of this human actor's open/acknowledged Failures.
  Uses the attention action and its existing read policy, without paging or
  a view-audit/head lock. Server-only `count_timeout_ms` and
  `statement_timeout_ms` may lower the fixed 2500/2000 ms ceilings.
  Returns `{:ok, nonnegative_integer}` or a closed metadata-read error.
  """
  def count_inbox_failures(opts) do
    SdrAgent.ReadDeadline.run(opts, fn timeout ->
      opts
      |> Keyword.put(:action, :attention)
      |> then(&GuardedCall.read_query(Failure, &1))
      |> Ash.count(timeout: timeout)
    end)
  end

  @doc "SQL-bounded, metadata-only Home attention candidates after a validated global cursor."
  def list_inbox_failures(actor, cursor), do: SdrAgent.Operations.Inbox.list(actor, cursor)

  defp do_update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update()
  end
end

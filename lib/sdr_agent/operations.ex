defmodule SdrAgent.Operations do
  @moduledoc """
  Operations bounded context (S2): durable background work as operators see
  it, and the failures that need a human.

  Resources (S7): `Operation` (the domain view of one Oban job) and
  `Failure` (a recorded error with class, severity, retryability and
  resolution). `IntegrationCredential` (S6) and `WebhookEvent` (S9) join
  later. Operations sits above Audit and Accounts (FKs to tenants and users)
  and below Agents, Sales, Research and Outreach, which open Failures here in
  the same transaction as the state change that causes them (S2 "Operator
  attention"): AgentRun failed / budget exhausted / system-cancelled, Lead
  blocked, Operation failed or discarded, a drifted model-provider
  attestation.

  Public API (every function takes `actor:`; writes run through
  `SdrAgent.Audit.Guard`, so refused auditor mutations are audited):

    * operations — `create_operation/2`, `start_operation/2`,
      `succeed_operation/2`, `fail_operation/3` (opens or links a Failure and
      discards at max attempts, one transaction), `retry_operation/2`,
      `cancel_operation/2`, `get_operation/2`, `find_operation/2`;
    * failures — `open_failure/2` (system actors), `acknowledge_failure/2`
      and `resolve_failure/3` (ADM, REV; system actors resolve with a system
      note), `get_failure/2`;
    * `list_attention/1` — the single operator-attention query: Failures in
      `open` or `acknowledged`, newest first (Dashboard and Operations views;
      ADM, REV, AUR, AUD).
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
  end

  ## Operations

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

  defp do_update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update()
  end
end

defmodule SdrAgent.Agents.Admission do
  @moduledoc """
  Reservation-time admission of real-model calls against owner-created
  grants (C9-02/03; R0 readiness packet "Changed backend action contracts").

  `admit/3` runs inside `SdrAgent.Agents.reserve_model_invocation/3`'s
  transaction for a ClaudeCLI call, after the run row lock and the explicit
  chain-head lock, and before the request payload and the invocation are
  written. It reads committed grant terms without locking grant rows (grant
  mutators lock their row, then the chain head, so an edit either committed
  before this read or waits for the reservation to commit). It selects the
  one allocation that may fund the call:

    * the run has a `usage_origin`, which with the call's purpose gives the
      trusted usage bucket (`SdrAgent.Agents.UsageBucket`);
    * its grant is of the run's tenant, `:active`, with
      `starts_at ≤ now < expires_at`, and lists the call's profile;
    * the allocation is of the same tenant and grant, its `profile_id` is
      unset or the call's, the bucket is in `applies_to`, and it is
      available at `now` (`available?/2`).

  Exactly one allocation must match. Its room is then checked: the grant's
  consumed attempts (ModelInvocations charged to it) below `total_attempts`,
  today's (UTC, by `reserved_at`) below `per_utc_day_attempts` when set, and
  the allocation's below its `attempts`. Attempts are never refunded.

  Refusals (`%Refusal{reason: reason}`), in order of the checks:
  `:no_usage_origin`, `:no_eligible_grant` (no grant passes the grant
  checks), `:no_allocation` (an eligible grant, but no allocation for this
  profile, bucket and time), `:ambiguous_allocation`, and
  `{:budget_exhausted, :grant | :grant_day | :allocation}`.

  `record_refusal/1` then commits the refusal on its own, after the
  reservation rolled back: one deduplicated `budget_exhausted` Failure and
  a `model.reservation.refused` audit event (metadata only).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Redactor
  alias SdrAgent.Repo

  @run_resource "SdrAgent.Agents.AgentRun"

  defmodule Refusal do
    @moduledoc """
    A refused reservation: the `reason` returned to the caller and the
    metadata recorded with the refusal (never the request content).
    """
    @enforce_keys [:reason, :tenant_id, :agent_run_id]
    defstruct [
      :reason,
      :tenant_id,
      :agent_run_id,
      :operation_id,
      :correlation_id,
      :usage_origin,
      :purpose,
      :profile_id,
      :bucket,
      :grant_id,
      :allocation_id,
      :idempotency_key
    ]
  end

  @doc """
  Admits a ClaudeCLI call of `profile_id` with `purpose` in the locked,
  freshly read `run`. Returns `{:ok, %{grant_id:, allocation_id:}}` or
  `{:error, %Refusal{}}`. Callers hold the run row and chain-head locks.
  """
  def admit(run, call, now) do
    purpose = Map.get(call, :purpose)
    profile_id = Map.get(call, :profile_id)

    refusal = %Refusal{
      reason: nil,
      tenant_id: run.tenant_id,
      agent_run_id: run.id,
      operation_id: run.operation_id,
      correlation_id: run.correlation_id,
      usage_origin: run.usage_origin,
      purpose: purpose,
      profile_id: profile_id,
      bucket: UsageBucket.bucket(run.usage_origin, purpose),
      idempotency_key: Map.get(call, :idempotency_key)
    }

    with :ok <- origin(refusal),
         {:ok, grants} <- eligible_grants(refusal, now),
         {:ok, grant, allocation} <- one_allocation(refusal, grants, now),
         :ok <- room(%{refusal | grant_id: grant.id, allocation_id: allocation.id}, grant, now) do
      {:ok, %{grant_id: grant.id, allocation_id: allocation.id}}
    end
  end

  @doc "Whether `grant` admits calls of `profile_id` at `now` (status, window, profile)."
  def grant_eligible?(grant, profile_id, now) do
    grant.status == :active and DateTime.compare(grant.starts_at, now) != :gt and
      DateTime.compare(now, grant.expires_at) == :lt and profile_id in grant.profile_ids
  end

  @doc "Whether `allocation` may fund a call of `profile_id` in `bucket` at `now`."
  def allocation_eligible?(allocation, profile_id, bucket, now) do
    (is_nil(allocation.profile_id) or allocation.profile_id == profile_id) and
      bucket in allocation.applies_to and available?(allocation, now)
  end

  @doc """
  An allocation is available at `now` iff (`released_at` is set, or
  `available_from` is unset or ≤ `now`) and (`available_until` is unset or
  `now` < it).
  """
  def available?(allocation, now) do
    opened? =
      not is_nil(allocation.released_at) or is_nil(allocation.available_from) or
        DateTime.compare(allocation.available_from, now) != :gt

    open? =
      is_nil(allocation.available_until) or
        DateTime.compare(now, allocation.available_until) == :lt

    opened? and open?
  end

  defp origin(%Refusal{usage_origin: nil} = refusal),
    do: {:error, %{refusal | reason: :no_usage_origin}}

  defp origin(_refusal), do: :ok

  defp eligible_grants(refusal, now) do
    ModelCallGrant
    |> Ash.Query.filter(
      tenant_id == ^refusal.tenant_id and status == :active and starts_at <= ^now and
        expires_at > ^now
    )
    |> Ash.Query.load(:allocations)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(
      &(&1.tenant_id == refusal.tenant_id and grant_eligible?(&1, refusal.profile_id, now))
    )
    |> case do
      [] -> {:error, %{refusal | reason: :no_eligible_grant}}
      grants -> {:ok, grants}
    end
  end

  defp one_allocation(refusal, grants, now) do
    matches =
      for grant <- grants,
          allocation <- grant.allocations,
          allocation.tenant_id == refusal.tenant_id and allocation.grant_id == grant.id,
          allocation_eligible?(allocation, refusal.profile_id, refusal.bucket, now),
          do: {grant, allocation}

    case matches do
      [{grant, allocation}] ->
        {:ok, grant, allocation}

      [] ->
        {:error, %{refusal | reason: :no_allocation, grant_id: single_grant(grants)}}

      _ ->
        {:error,
         %{
           refusal
           | reason: :ambiguous_allocation,
             grant_id: single_grant(matches_grants(matches))
         }}
    end
  end

  defp matches_grants(matches), do: Enum.map(matches, &elem(&1, 0))

  defp single_grant(grants) do
    case Enum.uniq_by(grants, & &1.id) do
      [grant] -> grant.id
      _ -> nil
    end
  end

  defp room(refusal, grant, now) do
    cond do
      consumed(grant_id: grant.id) >= grant.total_attempts ->
        {:error, %{refusal | reason: {:budget_exhausted, :grant}}}

      grant.per_utc_day_attempts && consumed_today(grant.id, now) >= grant.per_utc_day_attempts ->
        {:error, %{refusal | reason: {:budget_exhausted, :grant_day}}}

      consumed(allocation_id: refusal.allocation_id) >= allocation_attempts(grant, refusal) ->
        {:error, %{refusal | reason: {:budget_exhausted, :allocation}}}

      true ->
        :ok
    end
  end

  defp allocation_attempts(grant, refusal),
    do: Enum.find(grant.allocations, &(&1.id == refusal.allocation_id)).attempts

  defp consumed(filter) do
    ModelInvocation
    |> Ash.Query.do_filter(filter)
    |> Ash.count!(authorize?: false)
  end

  defp consumed_today(grant_id, now) do
    from = DateTime.new!(DateTime.to_date(now), ~T[00:00:00.000000], "Etc/UTC")
    until = DateTime.add(from, 1, :day)

    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant_id and reserved_at >= ^from and reserved_at < ^until)
    |> Ash.count!(authorize?: false)
  end

  ## Refusal reporting

  @doc """
  Commits `refusal` in its own guarded transaction as `agent_runtime`: the
  chain head is locked first, then an unresolved (open or acknowledged)
  `budget_exhausted` Failure of the same run with the same detail — the
  dedupe key `(reason, grant or none, run)`, stored as the Failure's
  redacted detail and matched by its `detail_sha256` — is reused, or a new
  critical one is opened; then `model.reservation.refused` is appended
  (reason, bucket, profile, grant/allocation, failure id and whether it
  was deduplicated). Concurrent and repeated refusals therefore open one
  Failure. Returns `{:ok, failure}` or `{:error, error}`.
  """
  def record_refusal(%Refusal{} = refusal) do
    agent = Actor.system(:agent_runtime, refusal.tenant_id)
    detail = detail(refusal)

    Audit.transaction(fn ->
      with {:ok, _head} <- Kernel.lock_head(refusal.tenant_id),
           {:ok, failure, deduplicated?} <- failure(refusal, detail, agent),
           {:ok, _event} <- Audit.append(event(refusal, failure, deduplicated?), actor: agent) do
        failure
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc "The detail reason recorded for a refusal reason (R0 packet, Operations.Failure)."
  def reason_name({:budget_exhausted, :grant}), do: "grant_exhausted"
  def reason_name({:budget_exhausted, :grant_day}), do: "grant_day_exhausted"
  def reason_name({:budget_exhausted, :allocation}), do: "allocation_exhausted"
  def reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure(refusal, detail, agent) do
    sha256 = :crypto.hash(:sha256, Redactor.redact(detail))

    Failure
    |> Ash.Query.for_read(:read, %{}, actor: agent)
    |> Ash.Query.filter(
      tenant_id == ^refusal.tenant_id and class == :budget_exhausted and
        subject_resource == ^@run_resource and subject_id == ^refusal.agent_run_id and
        detail_sha256 == ^sha256 and status in [:open, :acknowledged]
    )
    |> Ash.Query.sort(occurred_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, %Failure{} = existing} -> {:ok, existing, true}
      {:ok, nil} -> open_failure(refusal, detail, agent)
      {:error, error} -> {:error, error}
    end
  end

  defp open_failure(refusal, detail, agent) do
    attrs = %{
      operation_id: refusal.operation_id,
      subject_resource: @run_resource,
      subject_id: refusal.agent_run_id,
      class: :budget_exhausted,
      severity: :critical,
      retryable: false,
      message:
        "model call reservation refused: #{reason_name(refusal.reason)} " <>
          "(bucket #{refusal.bucket || "none"}, profile #{refusal.profile_id}); " <>
          "no real call is made until an admin grants an eligible allocation",
      detail: detail
    }

    with {:ok, failure} <- Operations.open_failure(attrs, actor: agent),
         do: {:ok, failure, false}
  end

  # The dedupe key, stored as the Failure's detail.
  defp detail(refusal) do
    Canonical.encode!(%{
      "kind" => "model_reservation_refused",
      "reason" => reason_name(refusal.reason),
      "grant_id" => refusal.grant_id || "none",
      "agent_run_id" => refusal.agent_run_id
    })
  end

  defp event(refusal, failure, deduplicated?) do
    %{
      event_type: "model.reservation.refused",
      category: :model,
      subject_resource: @run_resource,
      subject_id: refusal.agent_run_id,
      action: "reserve",
      agent_run_id: refusal.agent_run_id,
      correlation_id: refusal.correlation_id,
      idempotency_key: refusal.idempotency_key,
      payload: %{
        "reason" => reason_name(refusal.reason),
        "usage_origin" => name(refusal.usage_origin),
        "purpose" => name(refusal.purpose),
        "bucket" => name(refusal.bucket),
        "profile_id" => name(refusal.profile_id),
        "grant_id" => refusal.grant_id,
        "allocation_id" => refusal.allocation_id,
        "failure_id" => failure.id,
        "deduplicated" => deduplicated?
      }
    }
  end

  defp name(nil), do: nil
  defp name(atom) when is_atom(atom), do: Atom.to_string(atom)
end

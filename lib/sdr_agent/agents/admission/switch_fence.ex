defmodule SdrAgent.Agents.Admission.SwitchFence do
  @moduledoc """
  The model profile switch fence (C2-02b1, `docs/product/r0/c2-02b1-interface.md`,
  interface and entity PASS at cda8ee5): fresh, non-locking kernel reads made
  after the caller holds the tenant's chain head, so a switch request and
  every reservation and launch of the same tenant are totally ordered by the
  head (Read Committed: a statement started after the head was granted sees
  every transaction committed before it). No switch row is ever locked here.

  Reason `:profile_switch_fenced`, checks:

    * `:switch_pending` / `:switch_blocked` — the tenant has an open switch
      (reservation and launch);
    * `:reservation_provenance_missing` — at launch, once any switch was
      ever requested, the invocation's `model.invocation.reserved` event is
      missing or ambiguous (fails closed);
    * `:reserved_before_switch` — at launch, the invocation's reserved event
      has a lower chain sequence than some `model.profile.switch_requested`
      event of the tenant, whatever that switch's outcome (the epoch rule:
      a reservation never outlives a switch request).

  With no switch ever requested, nothing here refuses.
  """
  require Ash.Query

  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel

  @reason :profile_switch_fenced
  @requested "model.profile.switch_requested"
  @reserved "model.invocation.reserved"

  @doc "The fence's refusal reasons."
  def reasons, do: [@reason]

  @doc """
  The tenant's open switch, if any: `:ok`, or `{:error,
  :profile_switch_fenced, :switch_pending | :switch_blocked}`. Read errors
  are returned as `{:error, error}`.
  """
  def open_switch(tenant_id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and status in [:pending, :blocked])
    |> Ash.Query.select([:id, :status])
    |> Ash.read()
    |> case do
      {:ok, []} -> :ok
      {:ok, [%{status: status} | _]} -> {:error, @reason, :"switch_#{status}"}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Whether the named switch is still the tenant's open, pending switch at
  `generation` (the drain's revalidation, a fresh non-locking kernel read):
  `:ok`, `{:error, :switch_not_open}` (absent in the tenant, or not
  pending) or `{:error, :stale_server_generation}`. Read errors are
  `{:error, :drain_observation_failed}`.
  """
  def named_open(tenant_id, switch_id, generation) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^switch_id and tenant_id == ^tenant_id)
    |> Ash.Query.select([:id, :status, :server_generation])
    |> Ash.read_one()
    |> case do
      {:ok, %{status: :pending, server_generation: ^generation}} -> :ok
      {:ok, %{status: :pending}} -> {:error, :stale_server_generation}
      {:ok, _absent_or_closed} -> {:error, :switch_not_open}
      {:error, _error} -> {:error, :drain_observation_failed}
    end
  end

  @doc """
  Whether `invocation_id` was reserved before switch `switch_id` was
  requested (its reserved event's sequence is lower than the switch's own
  request event's): `:ok`, else `{:error, :drain_observation_failed}`
  (later, missing or ambiguous provenance fails closed).
  """
  def before_request(tenant_id, invocation_id, switch_id) do
    with {:ok, cutoff} <- request_sequence(tenant_id, switch_id),
         {:ok, reserved} <- reserved_sequence(tenant_id, invocation_id),
         true <- reserved < cutoff do
      :ok
    else
      _later_or_missing -> {:error, :drain_observation_failed}
    end
  end

  @doc """
  The launch-time fence of `invocation_id`: the open switch, then the epoch
  rule. `:ok` or `{:error, :profile_switch_fenced, check}`.
  """
  def launch(tenant_id, invocation_id) do
    with :ok <- open_switch(tenant_id), do: epoch(tenant_id, invocation_id)
  end

  defp epoch(tenant_id, invocation_id) do
    with {:ok, latest} <- latest_request(tenant_id) do
      case {latest, reserved_sequence(tenant_id, invocation_id)} do
        {nil, _reserved} ->
          :ok

        {_latest, :error} ->
          {:error, @reason, :reservation_provenance_missing}

        {latest, {:ok, reserved}} when reserved < latest ->
          {:error, @reason, :reserved_before_switch}

        {_latest, {:ok, _reserved}} ->
          :ok
      end
    end
  end

  @doc """
  The chain sequence of `invocation_id`'s one `model.invocation.reserved`
  event in the tenant: `{:ok, sequence}`, or `:error` when it is missing,
  ambiguous or unreadable.
  """
  def reserved_sequence(tenant_id, invocation_id) do
    tenant_id
    |> events(@reserved)
    |> Ash.Query.filter(model_invocation_id == ^invocation_id)
    |> one_sequence()
  end

  @doc """
  The chain sequence of switch `switch_id`'s one
  `model.profile.switch_requested` event in the tenant: `{:ok, sequence}`,
  or `:error` when it is missing, ambiguous or unreadable.
  """
  def request_sequence(tenant_id, switch_id) do
    tenant_id
    |> events(@requested)
    |> Ash.Query.filter(subject_id == ^switch_id)
    |> one_sequence()
  end

  defp latest_request(tenant_id) do
    tenant_id
    |> events(@requested)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, [%{sequence: sequence}]} -> {:ok, sequence}
      {:error, error} -> {:error, error}
    end
  end

  defp events(tenant_id, type) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and event_type == ^type)
    |> Ash.Query.select([:id, :sequence])
  end

  defp one_sequence(query) do
    case query |> Ash.Query.limit(2) |> Ash.read() do
      {:ok, [%{sequence: sequence}]} -> {:ok, sequence}
      _missing_ambiguous_or_unreadable -> :error
    end
  end
end

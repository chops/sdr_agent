defmodule SdrAgent.Agents.ReleaseDecision.Binding do
  @moduledoc """
  The gate cause a release is bound to (R0-07 slice C, rows G1 and R7-1;
  round-7 obligation 1): the `gate_cause_id` argument recorded by exactly
  the release's original `model.result.withheld` event (tenant, resource
  `SdrAgent.Agents.ModelResultRelease`, release id, event type). There is
  no mutable column; the event is the only binding.

  `{:ok, cause_id}` or `{:ok, nil}` — a nil or absent argument on a valid
  original event is the legitimate no-cause case — and `{:ok, nil}` for a
  release that is not withheld. A missing, duplicate or malformed event is
  not evidence that the cause was absent: `{:error, :binding_unavailable}`
  (fail closed).

  `SdrAgent.Agents.Changes.ReleaseDecision` compares it on replay: the same
  release fields with a different binding (including absent to present and
  present to absent) are a typed `ReleaseConflict`, never a replacement;
  an unavailable binding is refused. `SdrAgent.Agents.Changes.LinkGateCause`
  accepts a cause only when it is the bound one.
  """

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel

  @resource "SdrAgent.Agents.ModelResultRelease"
  @event "model.result.withheld"

  @type result :: {:ok, Ecto.UUID.t() | nil} | {:error, :binding_unavailable}

  @doc "The gate cause bound by `release`'s original withheld event (see the moduledoc)."
  @spec bound_cause(struct()) :: result()
  def bound_cause(%{disposition: :withheld, id: id, tenant_id: tenant_id})
      when is_binary(id) and is_binary(tenant_id) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and event_type == @event and subject_resource == @resource and
        subject_id == ^id
    )
    |> Ash.Query.limit(2)
    |> Ash.read()
    |> case do
      {:ok, events} -> from_events(events)
      {:error, _error} -> {:error, :binding_unavailable}
    end
  end

  def bound_cause(%{disposition: :withheld}), do: {:error, :binding_unavailable}
  def bound_cause(_release), do: {:ok, nil}

  @doc """
  The binding of the original-event candidates: exactly one event whose
  payload `arguments` is a map with a nil, absent or uuid `gate_cause_id`.
  """
  @spec from_events([map()]) :: result()
  def from_events([%{payload: %{"arguments" => %{} = arguments}}]) do
    case Map.get(arguments, "gate_cause_id") do
      nil -> {:ok, nil}
      cause when is_binary(cause) -> uuid(cause)
      _malformed -> {:error, :binding_unavailable}
    end
  end

  def from_events(_missing_duplicate_or_malformed), do: {:error, :binding_unavailable}

  defp uuid(cause) do
    case Ecto.UUID.cast(cause) do
      {:ok, ^cause} -> {:ok, cause}
      _ -> {:error, :binding_unavailable}
    end
  end
end

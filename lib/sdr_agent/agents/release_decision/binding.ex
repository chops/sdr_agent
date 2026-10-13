defmodule SdrAgent.Agents.ReleaseDecision.Binding do
  @moduledoc """
  The gate cause a release is bound to (R0-07 slice C, rows G1 and R7-1):
  the `gate_cause_id` argument recorded by the release's immutable
  `model.result.withheld` event, or nil when there is none. There is no
  mutable column; the event is the only binding.

  `SdrAgent.Agents.Changes.ReleaseDecision` compares it on replay: the same
  release fields with a different binding (including absent to present and
  present to absent) are a typed `ReleaseConflict`, never a replacement.
  """

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel

  @doc "The gate cause bound by `release`'s withheld event, or nil."
  @spec bound_cause(struct()) :: String.t() | nil
  def bound_cause(%{disposition: :withheld, id: id, tenant_id: tenant_id}) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and event_type == "model.result.withheld" and subject_id == ^id
    )
    |> Ash.read_one!()
    |> case do
      %AuditEvent{payload: %{"arguments" => %{"gate_cause_id" => cause}}} -> cause
      _ -> nil
    end
  end

  def bound_cause(_release), do: nil
end

defmodule SdrAgent.Outreach.Changes.ApplySuppression do
  @moduledoc """
  The same-transaction side effects of a new Suppression (S2): every open
  lead of a matching contact → stopped (`status_reason` "suppressed:
  <reason>"), its active/paused enrollments → stopped, its pending-review
  drafts → cancelled, and every delivery to the contact that is not yet
  claimed (pending, or waiting for a retry) → cancelled together with its
  queued draft and its still-granted approval (→ invalidated, `suppressed`).
  A delivery already claimed is in flight and is left to its outcome.

  Matching contacts: `email` scope — the contact email equals the value;
  `domain` scope — the contact email's domain equals the value. The
  enrollments, drafts and approvals are those of *every* lead of a matching
  contact, including leads already terminal; only the lead transition is
  limited to open leads.

  Lock order: the rows it will change are locked `FOR UPDATE` in a
  `before_action` hook (`SdrAgent.Outreach.Locks.targets/2`) — leads,
  enrollments, drafts, deliveries, approvals — before the suppression row
  and its audit event are written, i.e. before
  the chain-head lock, the order every other writer of those rows uses
  (`SdrAgent.Outreach.Delivery`), so a
  concurrent hand-off or approval either commits first (and is undone here)
  or waits and sees the stopped lead. The transitions run as the creating
  actor with the private side-effect markers
  (`SdrAgent.Sales.Checks.SuppressionContext`,
  `SdrAgent.Outreach.Checks.InternalWrite`). A replayed (already existing)
  suppression changes nothing. Any failing side effect rolls the suppression
  back.
  """
  use Ash.Resource.Change

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Locks
  alias SdrAgent.Sales.Checks.SuppressionContext

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&lock_targets/1)
    |> Ash.Changeset.after_action(fn changeset, suppression ->
      if Ash.Resource.get_metadata(suppression, :sdr_replayed),
        do: {:ok, suppression},
        else:
          apply_effects(changeset.context[:sdr_suppression_targets], suppression, context.actor)
    end)
  end

  defp lock_targets(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    scope = Ash.Changeset.get_attribute(changeset, :scope)
    value = changeset |> Ash.Changeset.get_attribute(:value) |> to_string()

    targets =
      Locks.targets(tenant_id, %{
        lead_ids: [],
        contact_ids: Locks.contacts(tenant_id, scope, value)
      })

    Ash.Changeset.put_context(changeset, :sdr_suppression_targets, targets)
  end

  defp apply_effects(targets, suppression, actor) do
    reason = suppression.reason

    steps =
      Enum.map(
        targets.approvals,
        &{&1, :invalidate, %{invalidated_reason: :suppressed}, InternalWrite}
      ) ++
        Enum.map(
          targets.deliveries,
          &{&1, :cancel, %{last_error: %{"reason" => "suppressed"}}, InternalWrite}
        ) ++
        Enum.map(
          targets.drafts,
          &{&1, :cancel, %{status_reason: "suppressed: #{reason}"}, InternalWrite}
        ) ++
        Enum.map(
          targets.enrollments,
          &{&1, :stop, %{stop_reason: stop_reason(reason)}, SuppressionContext}
        ) ++
        for(
          lead <- targets.leads,
          lead.status in Locks.open_leads(),
          do: {lead, :stop, %{status_reason: "suppressed: #{reason}"}, SuppressionContext}
        )

    Enum.reduce_while(steps, {:ok, suppression}, fn {record, action, attrs, marker}, ok ->
      record
      |> Ash.Changeset.for_update(action, attrs, actor: actor, context: marker.context())
      |> Ash.update(return_notifications?: true)
      |> case do
        {:ok, _record, _notifications} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp stop_reason(reason) when reason in [:unsubscribe_link, :unsubscribe_reply],
    do: :unsubscribe

  defp stop_reason(:hard_bounce), do: :bounced
  defp stop_reason(_reason), do: :suppressed
end

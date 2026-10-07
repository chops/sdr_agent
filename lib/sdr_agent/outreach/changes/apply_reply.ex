defmodule SdrAgent.Outreach.Changes.ApplyReply do
  @moduledoc """
  The same-transaction side effects of a *matched* Reply (S2 row Reply,
  spec §16 "cancel followups"), independent of any classification: the
  reply's enrollment (active or paused) → replied; its deliveries not yet
  claimed (pending, waiting for a retry) → cancelled, with their queued
  drafts → cancelled and still-granted approvals → invalidated
  (`campaign_closed` — the S2 reasons have none for a reply, and S8b's send
  gate maps "enrollment not active" to it as well); its drafts in review →
  cancelled; the lead (in outreach) → replied, entering the hand-off queue.
  A delivery already claimed is in flight and left to its outcome (its
  acceptance does not advance a replied enrollment). An unmatched reply
  changes nothing.

  Lock order: `SdrAgent.Outreach.Locks.targets/2` in a `before_action`,
  before the reply row and its audit event are written. The enrollment and
  lead transitions are WHK actions; the draft, delivery and approval writes
  carry the private `SdrAgent.Outreach.Checks.InternalWrite` marker.
  """
  use Ash.Resource.Change

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Locks

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&lock_targets/1)
    |> Ash.Changeset.after_action(fn changeset, reply ->
      case changeset.context[:sdr_reply_targets] do
        nil -> {:ok, reply}
        targets -> apply_effects(targets, reply, context.actor)
      end
    end)
  end

  defp lock_targets(changeset) do
    case Ash.Changeset.get_attribute(changeset, :lead_id) do
      nil ->
        changeset

      lead_id ->
        tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
        enrollment_id = Ash.Changeset.get_attribute(changeset, :enrollment_id)
        targets = Locks.targets(tenant_id, %{lead_ids: [lead_id], contact_ids: []})

        Ash.Changeset.put_context(changeset, :sdr_reply_targets, %{
          lead: Enum.find(targets.leads, &(&1.id == lead_id)),
          enrollment: Enum.find(targets.enrollments, &(&1.id == enrollment_id)),
          drafts: Enum.filter(targets.drafts, &(&1.enrollment_id == enrollment_id)),
          deliveries: Enum.filter(targets.deliveries, &(&1.enrollment_id == enrollment_id)),
          approvals: targets.approvals
        })
    end
  end

  defp apply_effects(targets, reply, actor) do
    draft_ids = MapSet.new(targets.drafts, & &1.id)
    marker = InternalWrite.context()

    steps =
      for(
        approval <- targets.approvals,
        MapSet.member?(draft_ids, approval.draft_id),
        do: {approval, :invalidate, %{invalidated_reason: :campaign_closed}, marker}
      ) ++
        Enum.map(
          targets.deliveries,
          &{&1, :cancel, %{last_error: %{"reason" => "replied", "reply_id" => reply.id}}, marker}
        ) ++
        Enum.map(targets.drafts, &{&1, :cancel, %{status_reason: "replied"}, marker}) ++
        enrollment_step(targets.enrollment) ++ lead_step(targets.lead)

    Enum.reduce_while(steps, {:ok, reply}, fn {record, action, attrs, context}, ok ->
      record
      |> Ash.Changeset.for_update(action, attrs, actor: actor, context: context)
      |> Ash.update(return_notifications?: true)
      |> case do
        {:ok, _record, _notifications} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp enrollment_step(nil), do: []
  defp enrollment_step(enrollment), do: [{enrollment, :mark_replied, %{}, %{}}]

  defp lead_step(%{status: :in_outreach} = lead), do: [{lead, :mark_replied, %{}, %{}}]
  defp lead_step(_lead), do: []
end

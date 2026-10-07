defmodule SdrAgent.Outreach.Changes.ApplySuppression do
  @moduledoc """
  The same-transaction side effects of a new Suppression (S2): every open
  lead of a matching contact → stopped (`status_reason` "suppressed:
  <reason>"), its active/paused enrollments → stopped, its granted approvals
  → invalidated (`suppressed`), its pending-review and queued drafts →
  cancelled.

  Matching contacts: `email` scope — the contact email equals the value;
  `domain` scope — the contact email's domain equals the value. The
  enrollments, drafts and approvals are those of *every* lead of a matching
  contact, including leads already terminal; only the lead transition is
  limited to open leads.

  Lock order: the rows it will change are locked `FOR UPDATE` in a
  `before_action` hook — leads, then enrollments, drafts and approvals —
  before the suppression row and its audit event are written, i.e. before
  the chain-head lock, the order every other writer of those rows uses, so a
  concurrent hand-off or approval either commits first (and is undone here)
  or waits and sees the stopped lead. The transitions run as the creating
  actor with the private side-effect markers
  (`SdrAgent.Sales.Checks.SuppressionContext`,
  `SdrAgent.Outreach.Checks.InternalWrite`). A replayed (already existing)
  suppression changes nothing. Any failing side effect rolls the suppression
  back.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Sales.CampaignEnrollment
  alias SdrAgent.Sales.Checks.SuppressionContext
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.Lead

  @open_leads [
    :new,
    :assigned,
    :researching,
    :qualifying,
    :qualified,
    :in_outreach,
    :replied,
    :blocked
  ]

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
    contact_ids = contacts(tenant_id, scope, value)

    # Every lead of a matching contact is locked, whatever its status: the
    # dependent work of a lead that is already terminal (e.g. stopped by an
    # operator) is still stopped, cancelled and invalidated; only the lead
    # transition itself is limited to open leads (review #13 MF1).
    leads = lock(Lead, tenant_id, contact_id: contact_ids, status: Lead.statuses())
    lead_ids = Enum.map(leads, & &1.id)

    enrollments =
      lock(CampaignEnrollment, tenant_id, lead_id: lead_ids, status: [:active, :paused])

    drafts = lock(Draft, tenant_id, lead_id: lead_ids, status: [:pending_review, :queued])
    approvals = lock(Approval, tenant_id, draft_id: Enum.map(drafts, & &1.id), status: [:granted])

    Ash.Changeset.put_context(changeset, :sdr_suppression_targets, %{
      leads: leads,
      enrollments: enrollments,
      drafts: drafts,
      approvals: approvals
    })
  end

  # Internal invariant reads (as Ash's own get_and_lock_for_update); nothing
  # read here is returned to the caller.
  defp contacts(tenant_id, :email, value) do
    Contact
    |> Ash.Query.filter(tenant_id == ^tenant_id and email == ^value)
    |> ids()
  end

  defp contacts(tenant_id, :domain, value) do
    Contact
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and fragment("lower(split_part(?::text, '@', 2))", email) == ^value
    )
    |> ids()
  end

  defp ids(query), do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)

  defp lock(_resource, _tenant_id, [{_field, []} | _]), do: []

  defp lock(resource, tenant_id, [{field, values}, {:status, statuses}]) do
    resource
    |> Ash.Query.filter(tenant_id == ^tenant_id and status in ^statuses)
    |> Ash.Query.do_filter([{field, [in: values]}])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)
  end

  defp apply_effects(targets, suppression, actor) do
    reason = suppression.reason

    steps =
      Enum.map(
        targets.approvals,
        &{&1, :invalidate, %{invalidated_reason: :suppressed}, InternalWrite}
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
          lead.status in @open_leads,
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

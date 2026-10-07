defmodule SdrAgent.Outreach.Locks do
  @moduledoc """
  The Outreach row locks taken before a stop-the-sequence write (a
  Suppression, a Reply) appends its first audit event — in the global lock
  order every Outreach writer uses (S8 choice 23, ADR-0009 "every row lock
  before the first append"): leads → enrollments → drafts → deliveries →
  approvals, each set in one `FOR UPDATE` query ordered by id.

  `targets/2` locks the given leads and *every* lead of the given contacts,
  whatever its status (S8a review MF1: the dependent work of an already
  terminal lead is still stopped; only the lead transition itself is
  limited to `open_leads/0`), then their active/paused enrollments, every
  open draft of those leads (judged on the locked rows: drafts in review,
  and queued drafts whose delivery is not yet claimed), those unclaimed
  deliveries (`pending`, `failed_retryable`) together with any further
  `delivery_ids` the caller will write (e.g. the accepted delivery a bounce
  moves — locked in the Delivery position of the order), and the drafts'
  granted approvals. A
  caller that locks a superset first (`SdrAgent.Outreach.Webhooks`) makes
  every later `targets/2` of the same transaction re-lock only rows it
  already holds.

  These are internal invariant reads (as Ash's own `get_and_lock_for_update`);
  nothing read here is returned to an actor.
  """

  require Ash.Query

  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Sales.CampaignEnrollment
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

  @doc "Open lead states (a suppression stops these; terminal leads keep their state)."
  def open_leads, do: @open_leads

  @doc "Ids of the contacts a suppression of `scope` / `value` (normalised) covers."
  def contacts(tenant_id, :email, value) do
    Contact
    |> Ash.Query.filter(tenant_id == ^tenant_id and email == ^value)
    |> ids()
  end

  def contacts(tenant_id, :domain, value) do
    Contact
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and fragment("lower(split_part(?::text, '@', 2))", email) == ^value
    )
    |> ids()
  end

  @doc """
  Locks and returns `%{leads, enrollments, drafts, deliveries, approvals}`
  for `lead_ids` and the open leads of `contact_ids`.
  """
  def targets(tenant_id, %{lead_ids: lead_ids, contact_ids: contact_ids} = spec) do
    extra_delivery_ids = Map.get(spec, :delivery_ids, [])

    leads =
      if lead_ids == [] and contact_ids == [] do
        []
      else
        Lead
        |> Ash.Query.filter(
          tenant_id == ^tenant_id and (id in ^lead_ids or contact_id in ^contact_ids)
        )
        |> locked()
      end

    lead_ids = Enum.map(leads, & &1.id)

    enrollments =
      lock(CampaignEnrollment, tenant_id,
        lead_id: [in: lead_ids],
        status: [in: [:active, :paused]]
      )

    drafts =
      lock(Draft, tenant_id, lead_id: [in: lead_ids], status: [in: [:pending_review, :queued]])

    queued_ids = for %{status: :queued, id: id} <- drafts, do: id

    locked_deliveries =
      if queued_ids == [] and extra_delivery_ids == [] do
        []
      else
        DeliveryOperation
        |> Ash.Query.filter(
          tenant_id == ^tenant_id and
            ((draft_id in ^queued_ids and state in [:pending, :failed_retryable]) or
               id in ^extra_delivery_ids)
        )
        |> locked()
      end

    deliveries =
      Enum.filter(
        locked_deliveries,
        &(&1.draft_id in queued_ids and &1.state in [:pending, :failed_retryable])
      )

    drafts =
      Enum.filter(drafts, fn draft ->
        draft.status == :pending_review or Enum.any?(deliveries, &(&1.draft_id == draft.id))
      end)

    approvals =
      lock(Approval, tenant_id,
        draft_id: [in: Enum.map(drafts, & &1.id)],
        status: [in: [:granted]]
      )

    %{
      leads: leads,
      enrollments: enrollments,
      drafts: drafts,
      deliveries: deliveries,
      locked_deliveries: locked_deliveries,
      approvals: approvals
    }
  end

  defp lock(_resource, _tenant_id, [{_field, [in: []]} | _]), do: []

  defp lock(resource, tenant_id, filters) do
    resource
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.do_filter(filters)
    |> locked()
  end

  defp locked(query) do
    query
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)
  end

  defp ids(query), do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
end

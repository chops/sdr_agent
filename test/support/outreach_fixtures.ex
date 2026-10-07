defmodule SdrAgent.OutreachFixtures do
  @moduledoc """
  Builders for Outreach tests (S8) on top of `SdrAgent.SDRCase`: a real
  draft produced by the agent's hand-off, the seeded operators, and short
  readers for drafts, revisions, citations and approvals.
  """

  import SdrAgent.SDRCase, only: [assign!: 2, drain!: 0, fixture_lead!: 2]

  alias SdrAgent.Accounts
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  @doc "The seeded operator with `role` (:admin, :reviewer, :auditor)."
  def operator!(ctx, role) do
    fixture = Enum.find(Fixtures.users(), &(&1.role == role))
    {:ok, user} = Accounts.get_user(fixture.id, actor: ctx.admin)
    user
  end

  @doc """
  Assigns fixture lead `key`, runs the agent and returns the draft it handed
  off with its run, lead, enrollment and current revision.
  """
  def drafted!(ctx, key \\ "01") do
    %{run: run} = assign!(ctx, key)
    %{success: 1} = drain!()
    lead = fixture_lead!(ctx, key)

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    %{draft: draft, run: run, lead: lead, revision: revision!(ctx, draft.current_revision_id)}
  end

  @doc "A draft revision by id (as ADM)."
  def revision!(ctx, id) do
    {:ok, revision} = Outreach.fetch(Outreach.DraftRevision, id, actor: ctx.admin)
    revision
  end

  @doc "A draft reloaded by id (as ADM)."
  def draft!(ctx, draft) do
    {:ok, draft} = Outreach.fetch(Outreach.Draft, draft.id, actor: ctx.admin)
    draft
  end

  @doc "Citations of a revision (as ADM)."
  def citations!(ctx, revision) do
    {:ok, citations} =
      Outreach.list_records(Outreach.RevisionCitation,
        filter: [draft_revision_id: revision.id],
        actor: ctx.admin
      )

    citations
  end

  @doc "Approvals of a draft, oldest first (as ADM)."
  def approvals!(ctx, draft) do
    {:ok, approvals} =
      Outreach.list_records(Outreach.Approval, filter: [draft_id: draft.id], actor: ctx.admin)

    approvals
  end

  @doc "Approval input binding the draft's current revision."
  def approval_input(revision),
    do: %{
      draft_revision_id: revision.id,
      content_sha256: Base.encode16(revision.content_sha256, case: :lower)
    }

  @doc "Approves the draft's current revision as `actor`."
  def approve!(ctx, draft, actor) do
    draft = draft!(ctx, draft)

    {:ok, approval} =
      Outreach.approve(draft, approval_input(revision!(ctx, draft.current_revision_id)),
        actor: actor
      )

    approval
  end

  @doc "A Sales record reloaded as ADM."
  def reload!(ctx, %resource{id: id}) do
    {:ok, record} = Sales.fetch(resource, id, actor: ctx.admin)
    record
  end

  @doc "The contact of a lead (as ADM)."
  def contact!(ctx, lead) do
    {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: ctx.admin)
    contact
  end

  @doc "The enrollment of a lead (as ADM)."
  def enrollment!(ctx, lead) do
    {:ok, [enrollment]} =
      Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

    enrollment
  end

  @doc "A record of `resource` reloaded by id (as ADM)."
  def outreach!(ctx, %resource{id: id}) do
    {:ok, record} = Outreach.fetch(resource, id, actor: ctx.admin)
    record
  end
end

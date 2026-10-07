defmodule SdrAgent.Outreach.Changes.BindApproval do
  @moduledoc """
  Approval `:approve` / `:reject`: binds the verdict to exactly what the
  reviewer saw (S2 Approval; S8 choice 2), in a `before_action` hook with the
  draft locked `FOR UPDATE` (lock order draft → chain head):

    * the approver is an active operator (the policy admits only ADM/REV);
    * the draft is `pending_review` and its *current* revision is the
      `draft_revision_id` argument with exactly the `content_sha256` (hex)
      argument — otherwise the verdict is stale and refused;
    * binding fields are set server-side: `draft_revision_id`,
      `revision_content_sha256`, `recipient_contact_id` and
      `recipient_email` (the contact's current email), `campaign_id`,
      `verdict`, `status`, `approver_authored_revision`;
    * for a grant, the contact is active, neither its email nor its domain
      is suppressed, and the campaign is not completed or archived;
    * the audit arguments `revision_author` (`{type: user, user_id}` or
      `{type: agent, agent_run_id}`) and `diff_hashes` (sha256 hex of the
      revision's two diffs, or nil) are computed here, never taken as input.

  Option `:verdict` — `:approved` or `:rejected`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.Contact

  @impl true
  def change(changeset, opts, context),
    do: Ash.Changeset.before_action(changeset, &bind(&1, opts[:verdict], context.actor))

  defp bind(changeset, verdict, actor) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    draft = lock(Draft, tenant_id, Ash.Changeset.get_attribute(changeset, :draft_id), :for_update)
    revision = draft && read(DraftRevision, draft.current_revision_id)
    contact = draft && lock(Contact, tenant_id, draft.recipient_contact_id, "FOR SHARE")
    campaign = draft && read(Campaign, draft.campaign_id)

    case refusal(changeset, verdict, actor, draft, revision, contact, campaign) do
      nil -> set(changeset, verdict, actor, draft, revision, contact)
      {field, message} -> Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp refusal(changeset, verdict, actor, draft, revision, contact, campaign) do
    review_refusal(changeset, actor, draft, revision) ||
      if(verdict == :approved, do: grant_refusal(contact, campaign))
  end

  # The verdict must be about the draft's current revision, as reviewed.
  defp review_refusal(changeset, actor, draft, revision) do
    arg = &Ash.Changeset.get_argument(changeset, &1)

    cond do
      not match?(%{status: :active}, actor) ->
        {:approver_id, "must be an active operator"}

      is_nil(draft) ->
        {:draft_id, "does not exist"}

      draft.status != :pending_review ->
        {:draft_id, "is #{draft.status}, not pending review"}

      arg.(:draft_revision_id) != draft.current_revision_id ->
        {:draft_revision_id, "is not the draft's current revision (stale review)"}

      String.downcase(to_string(arg.(:content_sha256))) != hex(revision.content_sha256) ->
        {:content_sha256, "does not match the current revision (stale review)"}

      true ->
        nil
    end
  end

  # A grant also needs a reachable, unsuppressed recipient in an open campaign.
  defp grant_refusal(contact, campaign) do
    cond do
      contact.status != :active ->
        {:recipient_contact_id, "the recipient is #{contact.status}"}

      suppressed?(contact) ->
        {:recipient_contact_id, "the recipient is suppressed"}

      campaign.status in [:completed, :archived] ->
        {:campaign_id, "the campaign is #{campaign.status}"}

      true ->
        nil
    end
  end

  defp set(changeset, verdict, actor, draft, revision, contact) do
    attrs = %{
      draft_revision_id: revision.id,
      revision_content_sha256: revision.content_sha256,
      recipient_contact_id: contact.id,
      recipient_email: contact.email,
      campaign_id: draft.campaign_id,
      verdict: verdict,
      status: if(verdict == :approved, do: :granted, else: :rejected),
      approver_authored_revision: revision.author_user_id == actor.id
    }

    changeset
    |> Ash.Changeset.force_change_attributes(attrs)
    |> Ash.Changeset.force_set_argument(:revision_author, author(revision))
    |> Ash.Changeset.force_set_argument(:diff_hashes, %{
      from_ai_baseline: digest(revision.diff_from_ai_baseline),
      from_parent: digest(revision.diff_from_parent)
    })
  end

  defp author(%{author_type: :human, author_user_id: id}), do: %{type: "user", user_id: id}
  defp author(%{author_type: :agent, agent_run_id: id}), do: %{type: "agent", agent_run_id: id}

  defp digest(nil), do: nil
  defp digest(text), do: :sha256 |> :crypto.hash(text) |> hex()

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp suppressed?(contact) do
    Suppression
    |> Ash.Query.for_read(:matching, %{email: String.downcase(to_string(contact.email))},
      authorize?: false
    )
    |> Ash.Query.filter(tenant_id == ^contact.tenant_id)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  # Internal invariant reads under lock; nothing read here is returned.
  defp lock(_resource, _tenant_id, nil, _lock), do: nil

  defp lock(resource, tenant_id, id, lock) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(lock)
    |> Ash.read_one!(authorize?: false)
  end

  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)
end

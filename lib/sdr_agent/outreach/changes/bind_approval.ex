defmodule SdrAgent.Outreach.Changes.BindApproval do
  @moduledoc """
  Approval `:approve` / `:reject`: binds the verdict to exactly what the
  reviewer saw (S2 Approval; S8 choice 2), in a `before_action` hook with the
  draft locked `FOR UPDATE` and its enrollment, campaign and contact
  `FOR SHARE` (lock order enrollment → draft → campaign → contact → chain
  head):

    * the approver is an active operator (the policy admits only ADM/REV),
      or, in D-237 prototype runtime (interfaces r6 IF-3 "Delegated
      approval"), the live resolved prototype operator whose `approver_id`
      (set by the scoped `ActorUser`) is the binding's anchor, an active
      `agent_operator` user of the operator's tenant;
    * a prototype operator approves only inside the compiled funding
      window `[starts_at, expires_at)` (`SdrAgent.Prototype.funding_entry/0`)
      at the decision instant, otherwise `prototype_outside_window`; the
      human path has no window;
    * the draft is `pending_review` and its *current* revision is the
      `draft_revision_id` argument with exactly the `content_sha256` (hex)
      argument — otherwise the verdict is stale and refused;
    * for a grant, the `recipient_email` argument (the email the reviewer
      saw; required) equals the locked contact's current email ignoring case
      — otherwise the verdict is stale and nothing is written (review #17
      MF1); a rejection does not compare it;
    * binding fields are set server-side: `draft_revision_id`,
      `revision_content_sha256`, `recipient_contact_id` and
      `recipient_email` (the contact's current email), `campaign_id`,
      `verdict`, `status`, `approver_authored_revision`;
    * for a grant, the contact is active, neither its email nor its domain
      is suppressed, and the campaign is not completed or archived;
    * the grant's delegated event arguments are server-derived: caller
      values of `approval_mode`, `delegation_id` and `prototype` are
      scrubbed; in D-237 prototype runtime the grant carries the assurance
      block (refused as `prototype_assurance_unavailable` without one), and
      the operator's grant also `"delegated_machine"` and its delegation id;
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
  alias SdrAgent.Sales.CampaignEnrollment
  alias SdrAgent.Sales.Contact

  @impl true
  def change(changeset, opts, context),
    do: Ash.Changeset.before_action(changeset, &bind(&1, opts[:verdict], context.actor))

  defp bind(changeset, verdict, actor) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    draft_id = Ash.Changeset.get_attribute(changeset, :draft_id)
    # Lock order (review #14 MF1): enrollment → draft → campaign → contact,
    # all before the first append — the grant's outbox row references the
    # enrollment, campaign and contact, so none of them may be waited for
    # under the chain head. The draft's references never change, so an
    # unlocked peek names the rows to lock.
    peek = read(Draft, draft_id)
    _enrollment = peek && lock(CampaignEnrollment, tenant_id, peek.enrollment_id, "FOR SHARE")
    draft = peek && lock(Draft, tenant_id, draft_id, :for_update)
    revision = draft && read(DraftRevision, draft.current_revision_id)
    campaign = draft && lock(Campaign, tenant_id, draft.campaign_id, "FOR SHARE")
    contact = draft && lock(Contact, tenant_id, draft.recipient_contact_id, "FOR SHARE")

    case refusal(changeset, verdict, actor, draft, revision, contact, campaign) do
      nil -> set(changeset, verdict, actor, draft, revision, contact)
      {field, message} -> Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp refusal(changeset, verdict, actor, draft, revision, contact, campaign) do
    review_refusal(changeset, actor, draft, revision) ||
      if(verdict == :approved, do: grant_refusal(changeset, contact, campaign))
  end

  # The verdict must be about the draft's current revision, as reviewed.
  defp review_refusal(changeset, actor, draft, revision) do
    arg = &Ash.Changeset.get_argument(changeset, &1)

    cond do
      refusal = approver_refusal(changeset, actor) ->
        refusal

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

  @inactive {:approver_id, "must be an active operator"}

  # A human approver is an active user (unchanged). A prototype operator is
  # re-resolved live, needs the binding's active anchor as `approver_id`, and
  # approves only inside the funding window (start inclusive, end exclusive)
  # at the decision instant under the draft lock; the human path has no
  # window. Only a build with the prototype authority has an operator clause.
  defp approver_refusal(_changeset, %{status: :active}), do: nil

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @outside_window {:approver_id,
                     "prototype_outside_window: delegated approval is outside the funding window"}

    defp approver_refusal(changeset, %SdrAgent.Actor{type: :prototype_operator} = actor) do
      cond do
        not active_operator?(changeset, actor) -> @inactive
        outside_window?() -> @outside_window
        true -> nil
      end
    end
  end

  defp approver_refusal(_changeset, _actor), do: @inactive

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp active_operator?(changeset, actor) do
      anchor_id = Ash.Changeset.get_attribute(changeset, :approver_id)

      is_binary(anchor_id) and SdrAgent.Prototype.operator?(actor) and
        binding_anchor?(anchor_id) and active_anchor?(anchor_id, actor.tenant_id)
    end

    defp binding_anchor?(anchor_id),
      do: match?({:ok, %{operator_user_id: ^anchor_id}}, SdrAgent.Prototype.binding())

    defp active_anchor?(anchor_id, tenant_id) do
      anchor =
        SdrAgent.Accounts.User
        |> Ash.Query.filter(id == ^anchor_id and tenant_id == ^tenant_id)
        |> Ash.read_one!(authorize?: false)

      match?(%{status: :active, role: :agent_operator}, anchor)
    end

    defp outside_window? do
      case SdrAgent.Prototype.funding_entry() do
        {:ok, %{starts_at: %DateTime{} = starts_at, expires_at: %DateTime{} = expires_at}} ->
          now = SdrAgent.Clock.utc_now()
          DateTime.compare(now, starts_at) == :lt or DateTime.compare(now, expires_at) != :lt

        _no_window ->
          true
      end
    end
  end

  # A grant also needs a reachable, unsuppressed recipient in an open campaign.
  defp grant_refusal(changeset, contact, campaign) do
    reviewed = Ash.Changeset.get_argument(changeset, :recipient_email)

    cond do
      not same_email?(reviewed, contact.email) ->
        {:recipient_email, "does not match the current recipient (stale review)"}

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

  defp same_email?(nil, _current), do: false

  defp same_email?(reviewed, current),
    do: String.downcase(to_string(reviewed)) == String.downcase(to_string(current))

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
    |> delegated(verdict, actor)
  end

  # The grant's delegated event arguments (interfaces r6 IF-3 / IF-5; Codex
  # b84b0491), server-derived only: every caller value is scrubbed first. In
  # prototype runtime the grant carries the assurance block (the label
  # belongs to the runtime, not the actor, and is never authority), and the
  # operator's grant also `approval_mode: "delegated_machine"` and its
  # delegation id; a missing block refuses (`prototype_assurance_unavailable`),
  # never an unlabelled grant. Ordinary runtime and every rejection carry none.
  @delegated [:approval_mode, :delegation_id, :prototype]

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp delegated(changeset, :approved, actor) do
      case SdrAgent.Prototype.runtime() do
        :prototype -> labelled(scrub(changeset), actor, SdrAgent.Prototype.assurance())
        _ordinary -> scrub(changeset)
      end
    end

    defp delegated(changeset, _verdict, _actor), do: scrub(changeset)

    defp labelled(changeset, actor, {:ok, %{} = block}) do
      changeset = Ash.Changeset.force_set_argument(changeset, :prototype, block)

      case actor do
        %SdrAgent.Actor{type: :prototype_operator, id: delegation_id} ->
          changeset
          |> Ash.Changeset.force_set_argument(:approval_mode, "delegated_machine")
          |> Ash.Changeset.force_set_argument(:delegation_id, delegation_id)

        _human ->
          changeset
      end
    end

    defp labelled(changeset, _actor, _unavailable) do
      Ash.Changeset.add_error(changeset,
        field: :approver_id,
        message: "prototype_assurance_unavailable: no assurance block for the grant"
      )
    end
  else
    defp delegated(changeset, _verdict, _actor), do: scrub(changeset)
  end

  defp scrub(changeset), do: Ash.Changeset.force_delete_argument(changeset, @delegated)

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

  defp read(_resource, nil), do: nil

  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)
end

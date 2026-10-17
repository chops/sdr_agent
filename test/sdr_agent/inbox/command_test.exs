defmodule SdrAgent.Inbox.CommandTest do
  @moduledoc """
  C1-03 A RED: fixed typed dispatch, current session, displayed source
  binding, three real draft mutations and durable no-mutation refusals.
  Retry remains unavailable until slice B, independently of layer 2.
  """
  use SdrAgent.SDRCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.InboxCommandFixtures
  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures

  alias SdrAgent.Accounts
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  @applied {:ok, %{outcome: :applied, refresh?: true}}
  @canary "C103_SYNTHETIC_PRIVATE_INPUT_7c32e6"

  setup ctx do
    drafted = drafted!(ctx)
    Map.merge(drafted, %{session: session!(ctx.admin)})
  end

  test "existing v1 item and freshness inputs remain byte-compatible during codec extraction",
       ctx do
    assert {:ok, [source]} = Outreach.list_inbox_drafts(ctx.admin, nil)
    {row, _request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    identity = {ctx.tenant.id, :outreach_drafts, :draft_review, ctx.draft.id, :email}

    facts = {
      source.draft.status,
      source.revision.id,
      hex(source.revision.content_sha256),
      source.contact.id,
      to_string(source.contact.email),
      source.contact.status,
      source.campaign.status,
      source.suppression_refs
    }

    secret = Application.fetch_env!(:sdr_agent, SdrAgentWeb.Endpoint)[:secret_key_base]

    digest = fn term ->
      :crypto.mac(:hmac, :sha256, secret, Canonical.encode!({"c1-inbox/1", term})) |> hex()
    end

    assert row.id == digest.({:item, identity})
    assert row.freshness_token == digest.({:freshness, identity, facts})
  end

  for role <- [:admin, :reviewer] do
    test "#{role} approves exactly the displayed email for capture once", ctx do
      actor = operator!(ctx, unquote(role))
      session = session!(actor)
      {row, request} = displayed!(session, ctx.draft, :approve_capture)
      assert command(session, request) == @applied

      [approval] = approvals!(ctx, ctx.draft)
      assert approval.verdict == :approved
      assert approval.approver_id == actor.id
      assert approval.draft_revision_id == row.revision_ref.id
      assert hex(approval.revision_content_sha256) == row.revision_ref.content_sha256
      assert to_string(approval.recipient_email) == row.recipient_binding.email
      delivery = delivery_of!(ctx, approval)
      assert delivery.provider == :capture
      assert draft!(ctx, ctx.draft).status == :queued
      assert_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)

      after_first = effects!(ctx, ctx.draft)
      granted = events_of_type(ctx.tenant, "outreach.approval.granted")
      error!(command(session, request), :stale, %{change: :lifecycle})
      assert effects!(ctx, ctx.draft) == after_first
      assert events_of_type(ctx.tenant, "outreach.approval.granted") == granted
    end
  end

  test "edit creates one source revision, preserves item identity, and invalidates the old token",
       ctx do
    reviewer = operator!(ctx, :reviewer)
    session = session!(reviewer)

    {row, request} =
      displayed!(session, ctx.draft, :edit_draft, %{
        subject: "A reviewed synthetic subject",
        body_text: ctx.revision.body_text,
        angle: "Synthetic angle",
        cta: "Synthetic question?"
      })

    assert command(session, request) == @applied
    current = draft!(ctx, ctx.draft)
    revision = revision!(ctx, current.current_revision_id)
    assert current.status == :pending_review
    assert revision.id != ctx.revision.id
    assert revision.parent_revision_id == ctx.revision.id
    assert revision.author_user_id == reviewer.id
    assert revision.subject == request.args.subject
    assert revision.body_text == request.args.body_text
    assert revision.angle == request.args.angle
    assert revision.cta == request.args.cta
    assert approvals!(ctx, ctx.draft) == []
    assert {:ok, page} = refresh(session)
    updated = item!(page, ctx.draft)
    assert updated.id == row.id
    refute updated.freshness_token == row.freshness_token

    after_first = effects!(ctx, ctx.draft)
    error!(command(session, request), :stale, %{change: :revision})
    assert effects!(ctx, ctx.draft) == after_first
    assert length(events_of_type(ctx.tenant, "outreach.draft.edited")) == 1
  end

  test "edit optional fields may be omitted; only a fresh explicit review can approve it", ctx do
    {_, request} =
      displayed!(ctx.session, ctx.draft, :edit_draft, %{
        subject: "Synthetic optional-fields edit",
        body_text: ctx.revision.body_text
      })

    {_, old_approval} = displayed!(ctx.session, ctx.draft, :approve_capture)
    assert command(ctx.session, request) == @applied
    error!(command(ctx.session, old_approval), :stale, %{change: :revision})
    assert approvals!(ctx, ctx.draft) == []
    {_, fresh_approval} = displayed!(ctx.session, ctx.draft, :approve_capture)
    assert command(ctx.session, fresh_approval) == @applied
    [approval] = approvals!(ctx, ctx.draft)
    assert approval.approver_authored_revision
  end

  test "reject records the source reason once, never a capture or a second rejection", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :reject_draft, %{reason: "Not suitable"})
    assert command(ctx.session, request) == @applied
    assert draft!(ctx, ctx.draft).status == :rejected
    [rejection] = approvals!(ctx, ctx.draft)
    assert rejection.verdict == :rejected
    assert rejection.reason == "Not suitable"

    assert {:ok, []} =
             Outreach.list_records(Outreach.DeliveryOperation,
               filter: [draft_id: ctx.draft.id],
               actor: ctx.admin
             )

    after_first = effects!(ctx, ctx.draft)
    error!(command(ctx.session, request), :stale, %{change: :lifecycle})
    assert effects!(ctx, ctx.draft) == after_first
    assert length(events_of_type(ctx.tenant, "outreach.approval.rejected")) == 1
    refute_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)
  end

  test "authentication precedes malformed command validation and actor/tenant injection", ctx do
    before = effects!(ctx, ctx.draft)

    for invalid_session <- [nil, "forged", ctx.admin, ctx.agent, %{}],
        request <- [
          nil,
          %{},
          %{action_id: :unknown},
          %{actor: ctx.admin, tenant_id: ctx.tenant.id}
        ] do
      error!(command(invalid_session, request), :forbidden)
    end

    assert effects!(ctx, ctx.draft) == before
  end

  test "strict command keys and exact action argument keys refuse permissive casting", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    before = effects!(ctx, ctx.draft)

    malformed = [
      Map.put(request, :actor, ctx.admin),
      Map.put(request, :tenant_id, ctx.tenant.id),
      Map.put(request, :producer, :outreach_drafts),
      Map.put(request, :resource, Outreach.Draft),
      Map.put(request, :module, Outreach),
      Map.put(request, :url, "/admin"),
      Map.put(request, "source_id", ctx.draft.id),
      Map.delete(request, :source_id),
      %{request | action_id: "approve_capture"},
      %{request | action_id: :destroy},
      %{request | source_id: "not-a-uuid"},
      %{request | args: Map.put(request.args, :verdict, :approved)},
      %{request | args: Map.put(request.args, "recipient_email", "other@example.test")},
      %{request | args: Map.new(request.args, fn {k, v} -> {Atom.to_string(k), v} end)},
      %{request | args: Map.put(request.args, :channel, :linkedin_message)},
      %{request | args: Map.delete(request.args, :recipient_email)},
      %{request | args: Map.put(request.args, :content_sha256, String.duplicate("G", 64))}
    ]

    for bad <- malformed, do: error!(command(ctx.session, bad), :invalid_input)
    assert effects!(ctx, ctx.draft) == before
  end

  test "forged digests and swapped item/source identities never dispatch a different draft",
       ctx do
    other = drafted!(ctx, "02")
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    before = effects!(ctx, ctx.draft)
    other_before = effects!(ctx, other.draft)

    for forged <- [
          %{request | item_id: String.duplicate("a", byte_size(request.item_id))},
          %{
            request
            | expected_freshness_token:
                String.duplicate("a", byte_size(request.expected_freshness_token))
          },
          %{request | source_id: other.draft.id}
        ] do
      error!(command(ctx.session, forged), :stale)
    end

    assert effects!(ctx, ctx.draft) == before
    assert effects!(ctx, other.draft) == other_before
  end

  for action <- [:approve_capture, :edit_draft, :reject_draft] do
    test "#{action} compares the displayed revision after a source edit", ctx do
      {_, request} =
        displayed!(ctx.session, ctx.draft, unquote(action), extra(ctx, unquote(action)))

      assert {:ok, edited} =
               Outreach.edit_draft(
                 ctx.draft,
                 %{subject: "Changed elsewhere", body_text: ctx.revision.body_text},
                 actor: ctx.admin
               )

      before = effects!(ctx, edited)
      error!(command(ctx.session, request), :stale, %{change: :revision})
      assert effects!(ctx, edited) == before
    end

    test "#{action} compares exact recipient even when the immutable revision is unchanged",
         ctx do
      {_, request} =
        displayed!(ctx.session, ctx.draft, unquote(action), extra(ctx, unquote(action)))

      contact = contact!(ctx, ctx.lead)

      assert {:ok, _} =
               Sales.update(contact, :change_email, %{email: "changed@example.test"},
                 actor: ctx.admin
               )

      before = effects!(ctx, ctx.draft)
      result = command(ctx.session, request)
      error!(result, :stale, %{change: :recipient})
      refute inspect(result) =~ "changed@example.test"
      assert effects!(ctx, ctx.draft) == before
    end

    test "auditor cannot forge #{action} using another actor's valid displayed binding", ctx do
      {_, request} =
        displayed!(ctx.session, ctx.draft, unquote(action), extra(ctx, unquote(action)))

      before = effects!(ctx, ctx.draft)
      denials = length(events_of_type(ctx.tenant, "authz.denied"))
      auditor_session = session!(operator!(ctx, :auditor))
      error!(command(auditor_session, request), :forbidden)
      assert effects!(ctx, ctx.draft) == before
      assert length(events_of_type(ctx.tenant, "authz.denied")) > denials
    end
  end

  for change <- [:revoke, :disable, :demote] do
    test "#{change} cannot reuse the earlier current operator", ctx do
      reviewer = operator!(ctx, :reviewer)
      session = session!(reviewer)
      {_, request} = displayed!(session, ctx.draft, :approve_capture)

      case unquote(change) do
        :revoke ->
          assert :ok =
                   AshAuthentication.TokenResource.Actions.revoke(
                     SdrAgent.Accounts.Token,
                     session
                   )

        :disable ->
          assert {:ok, _} = Accounts.change_status(reviewer, :disabled, actor: ctx.admin)

        :demote ->
          assert {:ok, _} = Accounts.change_role(reviewer, :auditor, actor: ctx.admin)
      end

      before = effects!(ctx, ctx.draft)
      error!(command(session, request), :forbidden)
      assert effects!(ctx, ctx.draft) == before
    end
  end

  test "non-user-purpose stored JWT cannot be supplied as the session", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)

    assert {:ok, token, _} =
             AshAuthentication.Jwt.token_for_user(ctx.admin, %{}, purpose: :password_reset)

    before = effects!(ctx, ctx.draft)
    error!(command(token, request), :forbidden)
    assert effects!(ctx, ctx.draft) == before
  end

  test "blank rejection and malformed edit content cause no source work or diagnostic leak",
       ctx do
    {_, reject} = displayed!(ctx.session, ctx.draft, :reject_draft, %{reason: "   "})

    {_, edit} =
      displayed!(ctx.session, ctx.draft, :edit_draft, %{
        subject: "Synthetic",
        body_text: %{private: @canary}
      })

    before = effects!(ctx, ctx.draft)
    malformed_reason = %{reject | args: %{reject.args | reason: %{private: @canary}}}

    log =
      capture_log(fn ->
        for request <- [reject, malformed_reason, edit] do
          result = command(ctx.session, request)
          error!(result, :invalid_input)
          refute inspect(result) =~ @canary
        end
      end)

    refute log =~ @canary
    refute inspect(events_of_type(ctx.tenant, "authz.denied")) =~ @canary
    assert effects!(ctx, ctx.draft) == before
  end

  test "foreign-tenant source is not authorized by an own-tenant signed item", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    foreign = drafted!(ctx, "02")
    foreign_tenant = Ecto.UUID.generate()

    tamper!("UPDATE drafts SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(foreign_tenant),
      Ecto.UUID.dump!(foreign.draft.id)
    ])

    before = effects!(ctx, ctx.draft)
    result = command(ctx.session, %{request | source_id: foreign.draft.id})
    error!(result, :not_found)
    nonexistent = command(ctx.session, %{request | source_id: Ecto.UUID.generate()})
    assert nonexistent == result
    assert result == {:error, %{reason: :not_found}}
    refute inspect(result) =~ foreign.draft.id
    refute inspect(result) =~ foreign.revision.subject
    assert effects!(ctx, ctx.draft) == before

    assert %{rows: [["pending_review", 0]]} =
             Repo.query!(
               "SELECT d.status, (SELECT count(*) FROM approvals a WHERE a.draft_id = d.id) FROM drafts d WHERE d.id = $1",
               [Ecto.UUID.dump!(foreign.draft.id)]
             )
  end

  test "a stale source action pair cannot dispatch retry or an arbitrary resource", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    before = effects!(ctx, ctx.draft)

    error!(
      command(ctx.session, %{request | action_id: :retry_run, args: %{confirm: true}}),
      :not_found
    )

    assert effects!(ctx, ctx.draft) == before
  end

  test "slice A does not enable retry capabilities", ctx do
    require_command!()

    failure =
      failure!(ctx, %{
        subject_resource: "SdrAgent.Agents.AgentRun",
        subject_id: ctx.run.id,
        retryable: true
      })

    assert {:ok, page} = refresh(ctx.session)
    row = item!(page, failure)
    retry = Enum.find(row.actions, &(&1.action_id == :retry_run))
    assert retry.availability == :blocked
    assert retry.blocked_reason == :guard_not_available
  end

  defp extra(ctx, :edit_draft),
    do: %{subject: "Explicit synthetic edit", body_text: ctx.revision.body_text}

  defp extra(_ctx, :reject_draft), do: %{reason: "Explicit synthetic rejection"}
  defp extra(_ctx, :approve_capture), do: %{}
end

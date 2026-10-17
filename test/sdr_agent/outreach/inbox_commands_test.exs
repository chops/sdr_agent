defmodule SdrAgent.Outreach.InboxCommandsTest do
  @moduledoc """
  C1-03 A source-context invariants through the public gateway. Raw writes
  are sandbox-only corruption/legacy fixtures, not command subjects or a
  way around production domain authorization.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxCommandFixtures
  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach

  @applied {:ok, %{outcome: :applied, refresh?: true}}

  setup ctx do
    Map.merge(drafted!(ctx), %{session: session!(ctx.admin)})
  end

  test "a completed campaign cannot be approved even using a freshly displayed token", ctx do
    # Model an already-closed campaign retaining a legacy pending row;
    # the subject must still use and obey the real source action.
    tamper!("UPDATE campaigns SET status = 'completed' WHERE id = $1", [
      Ecto.UUID.dump!(ctx.campaign_id)
    ])

    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    before = effects!(ctx, ctx.draft)
    error!(command(ctx.session, request), :blocked, %{blocked_reason: :campaign_closed})
    assert effects!(ctx, ctx.draft) == before
    refute_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)
  end

  test "inactive recipient blocks capture but not an exact fresh rejection", ctx do
    tamper!("UPDATE contacts SET status = 'archived' WHERE id = $1", [
      Ecto.UUID.dump!(ctx.draft.recipient_contact_id)
    ])

    {_, approve} = displayed!(ctx.session, ctx.draft, :approve_capture)

    {_, reject} =
      displayed!(ctx.session, ctx.draft, :reject_draft, %{reason: "No longer appropriate"})

    before = effects!(ctx, ctx.draft)
    error!(command(ctx.session, approve), :blocked, %{blocked_reason: :recipient_inactive})
    assert effects!(ctx, ctx.draft) == before
    assert command(ctx.session, reject) == @applied
    [rejection] = approvals!(ctx, ctx.draft)
    assert rejection.verdict == :rejected
    refute_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)
  end

  test "suppression blocks fresh capture while safe source rejection remains available", ctx do
    contact = contact!(ctx, ctx.lead)

    assert {:ok, _} =
             Outreach.suppress(%{scope: :email, value: to_string(contact.email)},
               actor: ctx.admin
             )

    # Suppression normally cancels the draft; restore only a legacy pending
    # status to exercise defense in depth at the command/action boundary.
    tamper!("UPDATE drafts SET status = 'pending_review' WHERE id = $1", [
      Ecto.UUID.dump!(ctx.draft.id)
    ])

    {_, approve} = displayed!(ctx.session, ctx.draft, :approve_capture)

    {_, reject} =
      displayed!(ctx.session, ctx.draft, :reject_draft, %{reason: "Recipient suppressed"})

    before = effects!(ctx, ctx.draft)
    error!(command(ctx.session, approve), :blocked, %{blocked_reason: :recipient_suppressed})
    assert effects!(ctx, ctx.draft) == before
    assert command(ctx.session, reject) == @applied
    assert draft!(ctx, ctx.draft).status == :rejected
    refute_enqueued(worker: SdrAgent.Outreach.DeliveryWorker)
  end

  for action <- [:approve_capture, :edit_draft, :reject_draft] do
    test "#{action} cannot reuse a formerly displayed synthetic recipient after real-data drift",
         ctx do
      {_, request} =
        displayed!(ctx.session, ctx.draft, unquote(action), arguments(ctx, unquote(action)))

      tamper!("UPDATE contacts SET email = $1 WHERE id = $2", [
        "private-c103@nonsynthetic-company-domain.com",
        Ecto.UUID.dump!(ctx.draft.recipient_contact_id)
      ])

      before = effects!(ctx, ctx.draft)
      result = command(ctx.session, request)
      error!(result, :blocked, %{blocked_reason: :real_data_disabled})
      refute inspect(result) =~ "private-c103"
      assert effects!(ctx, ctx.draft) == before
    end
  end

  for action <- [:approve_capture, :edit_draft, :reject_draft] do
    test "#{action} refuses a source whose referenced model output is now withheld", ctx do
      {_, request} =
        displayed!(ctx.session, ctx.draft, unquote(action), arguments(ctx, unquote(action)))

      grant = SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

      assert {:ok, %{allocations: [allocation]}} =
               SdrAgent.Agents.get_grant(grant.id, actor: ctx.admin)

      tamper!(
        "UPDATE model_invocations SET provider = 'claude_cli', ledger_generation = 2, profile_id = 'claude_cli_opus', grant_id = $1, allocation_id = $2 WHERE id = $3",
        [
          Ecto.UUID.dump!(grant.id),
          Ecto.UUID.dump!(allocation.id),
          Ecto.UUID.dump!(ctx.revision.model_invocation_id)
        ]
      )

      # Body-bearing source APIs may themselves withhold now. Compare raw,
      # tenant-owned structural facts, not forbidden revision content.
      before = structural!(ctx)
      result = command(ctx.session, request)
      error!(result, :blocked, %{blocked_reason: :witness_withheld})
      refute inspect(result) =~ ctx.revision.body_text
      assert structural!(ctx) == before
    end
  end

  test "a dangling revision fails closed, never mutates a different source revision", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)

    tamper!("UPDATE drafts SET current_revision_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(ctx.draft.id)
    ])

    before = structural!(ctx)
    error!(command(ctx.session, request), :producer_error)
    assert structural!(ctx) == before
  end

  test "another draft's current revision is not accepted as source-owned context", ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    other = drafted!(ctx, "02")

    tamper!("UPDATE drafts SET current_revision_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(other.revision.id),
      Ecto.UUID.dump!(ctx.draft.id)
    ])

    before = structural!(ctx)
    error!(command(ctx.session, request), :producer_error)
    assert structural!(ctx) == before
  end

  test "a count-read failure cannot revoke an independently fresh source command", ctx do
    require_command!()
    assert {:ok, page} = refresh(ctx.session, test_fault: {:pending_email_drafts, :returned})
    assert page.completeness == :partial
    row = item!(page, ctx.draft)
    assert page.totals.pending_email_drafts.status == :unavailable
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    request = %{request | item_id: row.id, expected_freshness_token: row.freshness_token}
    assert command(ctx.session, request) == @applied
    assert [_] = approvals!(ctx, ctx.draft)
  end

  test "edit cannot smuggle persisted binding fields through its action arguments", ctx do
    {_, request} =
      displayed!(ctx.session, ctx.draft, :edit_draft, %{
        subject: "Synthetic edit",
        body_text: ctx.revision.body_text
      })

    before = effects!(ctx, ctx.draft)

    for {key, value} <- [
          recipient_contact_id: Ecto.UUID.generate(),
          campaign_id: Ecto.UUID.generate(),
          origin_agent_run_id: ctx.run.id,
          risk_flags: [],
          author_user_id: ctx.admin.id,
          current_revision_id: ctx.revision.id
        ] do
      error!(
        command(ctx.session, %{request | args: Map.put(request.args, key, value)}),
        :invalid_input
      )
    end

    assert effects!(ctx, ctx.draft) == before
  end

  test "source recipient email comparison is exact even when the source approve action ignores case",
       ctx do
    {_, request} = displayed!(ctx.session, ctx.draft, :approve_capture)
    before = effects!(ctx, ctx.draft)

    changed = %{
      request
      | args: %{request.args | recipient_email: String.upcase(request.args.recipient_email)}
    }

    error!(command(ctx.session, changed), :stale, %{change: :recipient})
    assert effects!(ctx, ctx.draft) == before
  end

  defp arguments(ctx, :edit_draft),
    do: %{subject: "Synthetic edit", body_text: ctx.revision.body_text}

  defp arguments(_ctx, :reject_draft), do: %{reason: "Synthetic rejection"}
  defp arguments(_ctx, :approve_capture), do: %{}

  defp structural!(ctx) do
    Repo.query!(
      """
      SELECT d.status, d.current_revision_id,
        (SELECT count(*) FROM draft_revisions r WHERE r.draft_id = d.id),
        (SELECT count(*) FROM approvals a WHERE a.draft_id = d.id),
        (SELECT count(*) FROM delivery_operations o WHERE o.draft_id = d.id)
      FROM drafts d WHERE d.id = $1 AND d.tenant_id = $2
      """,
      [Ecto.UUID.dump!(ctx.draft.id), Ecto.UUID.dump!(ctx.tenant.id)]
    ).rows
  end
end

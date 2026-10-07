defmodule SdrAgent.Outreach.ApprovalTest do
  @moduledoc """
  S8a Approval (spec §15): a human verdict that, when granted, binds exactly
  one immutable revision (id + content hash) to exactly one recipient (the
  current contact email) and campaign; edit-then-approve by the same person
  is allowed and recorded; system actors and auditors never approve.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach

  defp denials(ctx), do: length(events_of_type(ctx.tenant, "authz.denied"))

  test "approve binds revision, hash, recipient, campaign and approver; draft → queued", ctx do
    %{draft: draft, revision: rev, lead: lead, run: run} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)
    contact = contact!(ctx, lead)

    assert {:ok, approval} = Outreach.approve(draft, approval_input(rev), actor: reviewer)

    assert {approval.status, approval.verdict} == {:granted, :approved}
    assert {approval.draft_id, approval.draft_revision_id} == {draft.id, rev.id}
    assert approval.revision_content_sha256 == rev.content_sha256
    assert approval.recipient_contact_id == contact.id
    assert to_string(approval.recipient_email) == to_string(contact.email)
    assert approval.campaign_id == ctx.campaign_id
    assert {approval.approver_id, approval.approver_authored_revision} == {reviewer.id, false}
    assert draft!(ctx, draft).status == :queued

    [granted] = events_of_type(ctx.tenant, "outreach.approval.granted")
    assert granted.actor_id == reviewer.id
    args = granted.payload["arguments"]
    assert args["revision_author"] == %{"type" => "agent", "agent_run_id" => run.id}
    assert args["diff_hashes"] == %{"from_ai_baseline" => nil, "from_parent" => nil}
  end

  test "a stale revision or hash is refused", ctx do
    %{draft: draft, revision: rev1} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)

    {:ok, edited} =
      Outreach.edit_draft(draft, %{subject: "New", body_text: rev1.body_text}, actor: reviewer)

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.approve(edited, approval_input(rev1), actor: reviewer)

    rev2 = revision!(ctx, edited.current_revision_id)

    wrong = %{
      approval_input(rev2)
      | content_sha256: Base.encode16(rev1.content_sha256, case: :lower)
    }

    assert {:error, %Ash.Error.Invalid{}} = Outreach.approve(edited, wrong, actor: reviewer)
    assert approvals!(ctx, draft) == []
    assert draft!(ctx, draft).status == :pending_review
  end

  test "edit-then-approve by the same reviewer is allowed and recorded", ctx do
    %{draft: draft, revision: rev1} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)

    {:ok, edited} =
      Outreach.edit_draft(draft, %{subject: "Mine", body_text: rev1.body_text}, actor: reviewer)

    rev2 = revision!(ctx, edited.current_revision_id)

    assert {:ok, approval} = Outreach.approve(edited, approval_input(rev2), actor: reviewer)
    assert approval.approver_authored_revision

    [granted] = events_of_type(ctx.tenant, "outreach.approval.granted")
    args = granted.payload["arguments"]
    assert args["revision_author"] == %{"type" => "user", "user_id" => reviewer.id}

    sha = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))

    assert args["diff_hashes"] == %{
             "from_ai_baseline" => sha.(rev2.diff_from_ai_baseline),
             "from_parent" => sha.(rev2.diff_from_parent)
           }
  end

  test "system actors and auditors cannot approve; each refusal is audited", ctx do
    %{draft: draft, revision: rev} = drafted!(ctx)
    before = denials(ctx)

    for actor <- [
          ctx.agent,
          SdrAgent.Actor.system(:delivery_worker, ctx.tenant.id),
          operator!(ctx, :auditor)
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Outreach.approve(draft, approval_input(rev), actor: actor)
    end

    assert denials(ctx) == before + 3
    assert approvals!(ctx, draft) == []
  end

  test "a suppressed or archived recipient cannot be approved", ctx do
    %{draft: draft, revision: rev, lead: lead} = drafted!(ctx)
    contact = contact!(ctx, lead)

    # A suppression row written behind the application's back (no side
    # effects ran): the approval still refuses the recipient.
    tamper!(
      """
      INSERT INTO suppressions (id, tenant_id, scope, value, reason, effective_at, trace_id, span_id, inserted_at)
      VALUES (gen_random_uuid(), $1, 'email', $2, 'manual', now(), $3, $4, now())
      """,
      [
        Ecto.UUID.dump!(ctx.tenant.id),
        to_string(contact.email),
        String.duplicate("a", 32),
        String.duplicate("b", 16)
      ]
    )

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.approve(draft, approval_input(rev), actor: ctx.admin)

    assert approvals!(ctx, draft) == []
  end

  test "reject records a rejected approval and ends the draft", ctx do
    %{draft: draft, revision: rev} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.reject(draft, Map.put(approval_input(rev), :reason, nil), actor: reviewer)

    assert {:ok, rejection} =
             Outreach.reject(draft, Map.put(approval_input(rev), :reason, "off-tone"),
               actor: reviewer
             )

    assert {rejection.verdict, rejection.status, rejection.reason} ==
             {:rejected, :rejected, "off-tone"}

    assert draft!(ctx, draft).status == :rejected
    assert [_] = events_of_type(ctx.tenant, "outreach.approval.rejected")
  end

  test "revoke returns the draft to review; a fresh approval can follow", ctx do
    %{draft: draft} = drafted!(ctx)
    reviewer = operator!(ctx, :reviewer)
    approval = approve!(ctx, draft, reviewer)

    for actor <- [operator!(ctx, :auditor), ctx.agent] do
      assert {:error, %Ash.Error.Forbidden{}} = Outreach.revoke(approval, actor: actor)
    end

    assert {:ok, revoked} = Outreach.revoke(approval, actor: ctx.admin)
    assert {revoked.status, revoked.revoked_by_id} == {:revoked, ctx.admin.id}
    assert revoked.revoked_at
    assert draft!(ctx, draft).status == :pending_review
    assert {:error, %Ash.Error.Invalid{}} = Outreach.revoke(revoked, actor: ctx.admin)

    approval2 = approve!(ctx, draft, reviewer)
    assert approval2.status == :granted
    assert Enum.map(approvals!(ctx, draft), & &1.status) |> Enum.sort() == [:granted, :revoked]
  end

  test "binding columns are immutable and terminal approvals frozen (trigger)", ctx do
    %{draft: draft} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    id = Ecto.UUID.dump!(approval.id)

    assert {:error, %Postgrex.Error{}} =
             raw_error("UPDATE approvals SET recipient_email = 'x@example.test' WHERE id = $1", [
               id
             ])

    assert {:error, %Postgrex.Error{}} = raw_error("DELETE FROM approvals WHERE id = $1", [id])

    {:ok, _} = Outreach.revoke(approval, actor: ctx.admin)

    assert {:error, %Postgrex.Error{}} =
             raw_error("UPDATE approvals SET status = 'granted' WHERE id = $1", [id])
  end
end

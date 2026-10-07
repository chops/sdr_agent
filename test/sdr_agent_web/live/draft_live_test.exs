defmodule SdrAgentWeb.DraftLiveTest do
  @moduledoc """
  S10a Draft review: the rendered revision with "click a sentence → see
  evidence" (RevisionCitation → EvidenceClaim → ResearchArtifact), the
  AI-vs-human diff, editing (a new human revision), approve/reject bound to
  the exact revision id and content hash on screen (a stale verdict is
  refused and shown), revoke, and the delivery with its receipts and the
  exact captured message (audited payload read). The auditor is read-only:
  every mutating event is refused by the domain and audited.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Outreach
  alias SdrAgent.Test.CaptureFaults

  defp open(conn, role, draft), do: conn |> sign_in(role) |> live(~p"/drafts/#{draft.id}")

  describe "reading a draft" do
    setup ctx, do: Map.merge(ctx, drafted!(ctx))

    test "renders the current revision with its binding", %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      assert has_element?(view, "#draft-header [data-status='pending_review']")
      assert has_element?(view, "#revision-subject", ctx.revision.subject)
      assert has_element?(view, "#binding-revision", "#1")
      assert has_element?(view, "#binding-hash", hex(ctx.revision.content_sha256))
    end

    test "clicking a cited sentence shows its evidence claim and source", %{conn: conn} = ctx do
      [citation | _] = citations!(ctx, ctx.revision)

      {:ok, claim} =
        SdrAgent.Research.fetch(SdrAgent.Research.EvidenceClaim, citation.evidence_claim_id,
          actor: ctx.admin
        )

      {:ok, artifact} =
        SdrAgent.Research.fetch(SdrAgent.Research.ResearchArtifact, claim.research_artifact_id,
          actor: ctx.admin
        )

      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)
      refute has_element?(view, "#citation-panel [data-claim-id]")

      view |> element("#revision-body [data-citation-id='#{citation.id}']") |> render_click()

      assert has_element?(view, "#citation-panel [data-claim-id='#{claim.id}']")
      assert has_element?(view, "#citation-panel blockquote", claim.quote)
      assert has_element?(view, "#citation-panel a[href='#{artifact.source_url}']")

      assert has_element?(
               view,
               "#citation-panel a[href='/leads/#{ctx.lead.id}?claim=#{claim.id}']"
             )
    end

    test "an auditor's draft view is recorded with the draft id", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = open(conn, :auditor, ctx.draft)

      assert has_element?(view, "#revision-subject")
      refute has_element?(view, "#approve-form")
      refute has_element?(view, "#reject-form")
      refute has_element?(view, "#edit-toggle")

      assert [%{target_resource: "SdrAgent.Outreach.Draft", target_ref: ref}] =
               accesses_of(ctx, auditor)

      assert ref == ctx.draft.id
    end
  end

  describe "editing and deciding" do
    setup ctx, do: Map.merge(ctx, drafted!(ctx))

    test "an edit creates a human revision and shows the AI-vs-human diff", %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)
      refute has_element?(view, "#ai-diff [data-op='ins']")

      view |> element("#edit-toggle") |> render_click()

      view
      |> form("#edit-form",
        revision: %{
          subject: "Edited subject line",
          body_text: ctx.revision.body_text <> "\nP.S. edited"
        }
      )
      |> render_submit()

      assert has_element?(view, "#binding-revision", "#2")
      assert has_element?(view, "#revision-subject", "Edited subject line")
      assert has_element?(view, "#ai-diff [data-op='ins']", "Edited subject line")
      assert has_element?(view, "#ai-diff [data-op='del']", ctx.revision.subject)

      draft = draft!(ctx, ctx.draft)
      assert revision!(ctx, draft.current_revision_id).author_type == :human
    end

    test "approve sends the revision id and hash shown; the draft is queued",
         %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      view |> form("#approve-form") |> render_submit()

      assert has_element?(view, "#draft-header [data-status='queued']")
      [approval] = approvals!(ctx, ctx.draft)

      assert {approval.verdict, approval.status, approval.draft_revision_id} ==
               {:approved, :granted, ctx.revision.id}

      assert has_element?(view, "#approval-#{approval.id} [data-status='granted']")

      assert has_element?(
               view,
               "#delivery-#{delivery_of!(ctx, approval).id} [data-state='pending']"
             )
    end

    test "a stale approval (the draft changed after it was shown) is refused and explained",
         %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      elsewhere = %{subject: "Changed elsewhere", body_text: ctx.revision.body_text}
      {:ok, _edited} = Outreach.edit_draft(ctx.draft, elsewhere, actor: ctx.admin)

      view |> form("#approve-form") |> render_submit()

      assert has_element?(view, "#review-error", "stale review")
      assert approvals!(ctx, ctx.draft) == []
      assert draft!(ctx, ctx.draft).status == :pending_review
      assert has_element?(view, "#binding-revision", "#2")
    end

    test "the recipient is shown and re-checked at confirmation; a changed email must be confirmed again",
         %{conn: conn} = ctx do
      contact = contact!(ctx, ctx.lead)
      moved = "avery.moved@brightpath-freight.test"
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)
      assert has_element?(view, "#binding-recipient", to_string(contact.email))

      assert has_element?(
               view,
               "#approve-form input[name='approve[recipient_email]'][value='#{contact.email}']"
             )

      {:ok, _moved} =
        SdrAgent.Sales.update(contact, :change_email, %{email: moved}, actor: ctx.admin)

      view |> form("#approve-form") |> render_submit()

      assert has_element?(view, "#review-error", "does not match the current recipient")
      assert has_element?(view, "#binding-recipient", moved)
      assert approvals!(ctx, ctx.draft) == []

      view |> form("#approve-form") |> render_submit()

      [approval] = approvals!(ctx, ctx.draft)
      assert to_string(approval.recipient_email) == moved
      assert has_element?(view, "#approval-#{approval.id} [data-recipient='#{moved}']")
    end

    test "a reviewer's approve with a mismatched recipient is refused by the domain as stale",
         %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      render_submit(view, "approve", %{
        "approve" => %{
          "draft_revision_id" => ctx.revision.id,
          "content_sha256" => hex(ctx.revision.content_sha256),
          "recipient_email" => "someone.else@brightpath-freight.test"
        }
      })

      assert has_element?(view, "#review-error", "stale review")
      assert approvals!(ctx, ctx.draft) == []
    end

    test "reject requires a reason and records it", %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      view
      |> form("#reject-form", reject: %{reason: "Tone is off for this persona"})
      |> render_submit()

      assert has_element?(view, "#draft-header [data-status='rejected']")
      [approval] = approvals!(ctx, ctx.draft)
      assert {approval.verdict, approval.reason} == {:rejected, "Tone is off for this persona"}
    end

    test "revoking a granted approval returns the draft to review", %{conn: conn} = ctx do
      approval = approve!(ctx, ctx.draft, user!(ctx, :reviewer))
      {:ok, view, _html} = open(conn, :reviewer, ctx.draft)

      view |> element("#revoke-#{approval.id}") |> render_click()

      assert has_element?(view, "#draft-header [data-status='pending_review']")
      assert outreach!(ctx, approval).status == :revoked
    end
  end

  describe "delivery" do
    test "shows the accepted delivery, its receipts and the exact captured message",
         %{conn: conn} = ctx do
      %{draft: draft, delivery: op} = approved!(ctx)
      assert %{success: 1} = deliver!()
      op = outreach!(ctx, op)
      reviewer = user!(ctx, :reviewer)

      {:ok, view, _html} = open(conn, :reviewer, draft)

      assert has_element?(view, "#delivery-#{op.id} [data-state='accepted']")

      for receipt <- receipts!(ctx, op) do
        assert has_element?(view, "#receipt-#{receipt.id} [data-kind='#{receipt.kind}']")
      end

      refute has_element?(view, "#captured-message-#{op.id}")
      before = length(accesses_of(ctx, reviewer))

      view |> element("#show-message-#{op.id}") |> render_click()

      {:ok, rendered} = SdrAgent.Audit.read_content(op.rendered_sha256, actor: ctx.admin)

      [subject_line | _] =
        rendered |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "Subject: "))

      assert has_element?(view, "#captured-message-#{op.id}", subject_line)
      assert has_element?(view, "#captured-message-#{op.id}", "Unsubscribe:")

      accesses = accesses_of(ctx, reviewer)
      assert length(accesses) == before + 1
      assert %{access_kind: :payload_view, target_ref: ref} = List.last(accesses)
      assert ref == hex(op.rendered_sha256)
    end

    test "a delivery waiting for a retry can be cancelled", %{conn: conn} = ctx do
      start_supervised!(CaptureFaults)
      put_env!(:capture_faults, CaptureFaults)
      CaptureFaults.plan(:before_capture, [{:error, {:retryable, :rate_limited}}])
      %{draft: draft, delivery: op} = approved!(ctx)
      assert %{success: 1} = deliver!()

      {:ok, view, _html} = open(conn, :reviewer, draft)
      assert has_element?(view, "#delivery-#{op.id} [data-state='failed_retryable']")

      view |> element("#cancel-retry-#{op.id}") |> render_click()

      assert has_element?(view, "#delivery-#{op.id} [data-state='cancelled']")
      assert outreach!(ctx, op).state == :cancelled
    end
  end

  describe "the auditor is read-only" do
    setup ctx do
      auditor = user!(ctx, :auditor)
      Map.merge(ctx, Map.put(drafted!(ctx), :auditor, auditor))
    end

    test "approve, reject and edit events are refused by the domain and audited",
         %{conn: conn} = ctx do
      {:ok, view, _html} = open(conn, :auditor, ctx.draft)

      # The forged event copies the rendered approve form, recipient included.
      binding = %{
        "draft_revision_id" => ctx.revision.id,
        "content_sha256" => hex(ctx.revision.content_sha256),
        "recipient_email" => to_string(contact!(ctx, ctx.lead).email)
      }

      render_submit(view, "approve", %{"approve" => binding})
      assert has_element?(view, "#flash-error")
      render_submit(view, "reject", %{"reject" => %{"reason" => "nope"}})
      render_submit(view, "save_edit", %{"revision" => %{"subject" => "x", "body_text" => "y"}})

      assert approvals!(ctx, ctx.draft) == []
      draft = draft!(ctx, ctx.draft)
      assert {draft.status, draft.current_revision_id} == {:pending_review, ctx.revision.id}
      assert length(denials_of(ctx, ctx.auditor)) == 3
    end

    for {label, recipient} <- [
          {"missing", :missing},
          {"malformed", "not an email"},
          {"mismatched", "someone.else@brightpath-freight.test"}
        ] do
      test "an auditor's approve with a #{label} recipient reaches the domain and is denied once",
           %{conn: conn} = ctx do
        {:ok, view, _html} = open(conn, :auditor, ctx.draft)

        binding = %{
          "draft_revision_id" => ctx.revision.id,
          "content_sha256" => hex(ctx.revision.content_sha256)
        }

        binding =
          case unquote(recipient) do
            :missing -> binding
            email -> Map.put(binding, "recipient_email", email)
          end

        render_submit(view, "approve", %{"approve" => binding})

        assert has_element?(view, "#flash-error")
        assert approvals!(ctx, ctx.draft) == []
        assert draft!(ctx, ctx.draft).status == :pending_review
        assert [_denied_once] = denials_of(ctx, ctx.auditor)
      end
    end

    test "revoke and cancel-retry events are refused by the domain and audited",
         %{conn: conn} = ctx do
      approval = approve!(ctx, ctx.draft, user!(ctx, :reviewer))
      delivery = delivery_of!(ctx, approval)
      {:ok, view, _html} = open(conn, :auditor, ctx.draft)

      refute has_element?(view, "#revoke-#{approval.id}")
      render_click(view, "revoke", %{"id" => approval.id})
      render_click(view, "cancel_retry", %{"id" => delivery.id})

      assert has_element?(view, "#flash-error")
      assert outreach!(ctx, approval).status == :granted
      assert outreach!(ctx, delivery).state == :pending
      assert length(denials_of(ctx, ctx.auditor)) == 2
    end
  end
end

defmodule SdrAgentWeb.GoldenPathTest do
  @moduledoc """
  S13 golden-path acceptance (build plan "Golden path"), driven through the
  operator console exactly as the demo script runs it, on the deterministic
  seed and the fake model:

    1. seed (fictional ICP, campaign, accounts, contacts; `OperatorCase`);
    2. the reviewer assigns lead 01 → `ResearchLeadFlow` /
       `PrepareOutreachFlow` on fixture providers (research job drained);
    3. evidence and qualification on the lead page; a draft with cited
       evidence in the review queue;
    4. the reviewer approves on the draft page — the form carries the
       revision id, content hash and the recipient email *displayed*;
    5. the delivery job runs → local capture → `accepted`, captured receipt,
       the exact message readable through the audited payload path;
    6. **(S9 slot)** signed simulated replies (interested, unsubscribe) —
       added in `replies/2` when this branch carries S9a (main `b26be34`):
       `WebhookFixtures.reply_body/3` + `signed_headers/2` POSTed to the
       webhook, `Oban.drain_queue(queue: :integration)`, then suppression and
       follow-up cancellation asserted;
    7. the audit trail holds every step in causal order and the chain
       verifies.

  Postgres-only reconstruction, restart/idempotency and the browser smoke
  are separate S13 part-2 acceptance tests.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Outreach

  @golden_events [
    "sdr.lead.assigned",
    "outreach.draft.proposed",
    "outreach.approval.granted",
    "outreach.delivery.requested",
    "outreach.delivery.claimed",
    "outreach.delivery.accepted",
    "outreach.draft.sent"
  ]

  test "seed → assign → research/qualify → draft → approve → capture → verified chain",
       %{conn: conn} = ctx do
    conn = sign_in(conn, :reviewer)
    lead = fixture_lead!(ctx, "01")
    contact = contact!(ctx, lead)

    # 2. Assign from the lead page; the agent's job runs.
    {:ok, lead_view, _html} = live(conn, ~p"/leads/#{lead.id}")
    lead_view |> element("#assign-lead") |> render_click()
    assert %{success: 1, failure: 0} = drain!()

    # 3. Evidence, qualification and the draft are on the lead page.
    {:ok, lead_view, _html} = live(conn, ~p"/leads/#{lead.id}")
    assert has_element?(lead_view, "#qualification-score")
    assert has_element?(lead_view, "#qualification-evidence")

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    assert has_element?(lead_view, "#lead-drafts a[href='/drafts/#{draft.id}']")

    {:ok, review, _html} = live(conn, ~p"/review")
    assert has_element?(review, "#review-queue-#{draft.id}")

    # 4. Approve what is displayed: revision, hash and recipient email.
    {:ok, draft_view, _html} = live(conn, ~p"/drafts/#{draft.id}")
    assert has_element?(draft_view, "#binding-recipient", to_string(contact.email))
    assert has_element?(draft_view, "#revision-body [data-citation-id]")
    draft_view |> form("#approve-form") |> render_submit()

    [approval] = approvals!(ctx, draft)

    assert {approval.status, to_string(approval.recipient_email)} ==
             {:granted, to_string(contact.email)}

    assert approval.approver_id == user!(ctx, :reviewer).id

    # 5. Delivery: local capture only, exact message through the audited read.
    deliver!()
    delivery = delivery_of!(ctx, approval)
    assert delivery.state == :accepted
    assert Enum.any?(receipts!(ctx, delivery), &(&1.kind == :captured))

    {:ok, draft_view, _html} = live(conn, ~p"/drafts/#{draft.id}")
    assert has_element?(draft_view, "#draft-header [data-status='sent']")
    draft_view |> element("#show-message-#{delivery.id}") |> render_click()
    message = render(draft_view)
    assert message =~ "To: "
    assert message =~ to_string(contact.email)
    assert message =~ "List-Unsubscribe"

    # 6. S9 slot: signed simulated replies (see the moduledoc).
    :ok = replies(ctx, delivery)

    # 7. Every golden-path step is in the ledger, in causal order; it verifies.
    types = ctx.tenant |> events() |> Enum.map(& &1.event_type)
    assert subsequence?(@golden_events, types), inspect(types -- (types -- @golden_events))
    assert {:ok, %{valid?: true, issues: []}} = Audit.verify_chain(actor: ctx.aud)
  end

  # Added with S9a on this branch: signed interested + unsubscribe replies,
  # dedupe, suppression and follow-up cancellation. Until then the golden
  # path ends at capture (S13 part-2 TODO in notes/features/s13-acceptance.org).
  defp replies(_ctx, _delivery), do: :ok

  defp subsequence?([], _list), do: true
  defp subsequence?(_wanted, []), do: false
  defp subsequence?([x | rest], [x | tail]), do: subsequence?(rest, tail)
  defp subsequence?(wanted, [_ | tail]), do: subsequence?(wanted, tail)
end

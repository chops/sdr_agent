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
    6. signed simulated replies through the webhook endpoint, as
       `mix sdr.demo.reply` sends them (`SdrAgent.Demo.Replies`): an
       *interested* reply to lead 01 is matched, classified and lands in the
       hand-off queue; a second lead (02) is drafted, approved by a human
       and captured, and its *unsubscribe* reply suppresses the recipient
       and stops the lead (S9);
    7. the audit trail holds every step in causal order and the chain
       verifies.

  Postgres-only reconstruction, restart/idempotency and the browser smoke
  are separate S13 part-2 acceptance tests.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.WebhookFixtures, only: [process!: 0, replies!: 1, suppressions!: 1]

  alias SdrAgent.Audit
  alias SdrAgent.Demo.Replies
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

    # 6. Signed simulated replies: interested (lead 01), unsubscribe (lead 02).
    :ok = replies(ctx, lead, delivery)

    # 7. Every golden-path step is in the ledger, in causal order; it verifies.
    types = ctx.tenant |> events() |> Enum.map(& &1.event_type)
    assert subsequence?(@golden_events, types), inspect(types -- (types -- @golden_events))
    assert {:ok, %{valid?: true, issues: []}} = Audit.verify_chain(actor: ctx.aud)
  end

  defp replies(ctx, lead, delivery) do
    assert {:ok, 202} = Replies.post(:interested, delivery, plug: SdrAgentWeb.Endpoint)
    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)

    assert [%{match_status: :matched, lead_id: lead_id}] = replies!(ctx)
    assert lead_id == lead.id

    assert {:ok, [%{assessment: %{classification: :interested}}]} =
             Outreach.list_handoff_queue(actor: ctx.admin)

    # A second lead, approved by a human reviewer and captured, unsubscribes.
    %{run: _} = assign!(ctx, "02")
    assert %{success: 1} = drain!()
    second = fixture_lead!(ctx, "02")

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: second.id], actor: ctx.admin)

    approval = approve!(ctx, draft, user!(ctx, :reviewer))
    deliver!()
    unsubscribed = delivery_of!(ctx, approval)
    assert unsubscribed.state == :accepted

    assert {:ok, 202} = Replies.post(:unsubscribe, unsubscribed, plug: SdrAgentWeb.Endpoint)
    assert %{success: 1} = process!()

    assert [_] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))
    assert fixture_lead!(ctx, "02").status == :stopped
    :ok
  end

  defp subsequence?([], _list), do: true
  defp subsequence?(_wanted, []), do: false
  defp subsequence?([x | rest], [x | tail]), do: subsequence?(rest, tail)
  defp subsequence?(wanted, [_ | tail]), do: subsequence?(wanted, tail)
end

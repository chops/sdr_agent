defmodule SdrAgent.Outreach.DeliveryOutcomeTest do
  @moduledoc """
  S9 provider outcomes and the unsubscribe link through the signed webhook:
  `delivered` and `bounce` move an accepted delivery (S8b's unwired
  `mark_delivered` / `mark_bounced`) with a receipt naming the WebhookEvent;
  a bounce or complaint deterministically suppresses the recipient; a valid
  unsubscribe-link token (`Unsubscribe.verify/3`) suppresses the contact, a
  forged one suppresses nothing.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Operations
  alias SdrAgent.Operations.WebhookEvent

  defp delivered!(ctx) do
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    Map.put(approved, :delivery, outreach!(ctx, approved.delivery))
  end

  defp event!(type, body) do
    assert {:ok, %{status: :accepted, event: event}} = ingest!(type, body)
    assert %{success: 1} = process!()
    event
  end

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  test "delivered: accepted → delivered with a delivered receipt naming the event", ctx do
    %{delivery: op} = delivered!(ctx)
    event = event!("delivered", outcome_body("delivered", op))

    op = outreach!(ctx, op)
    assert op.state == :delivered
    assert op.confirmed_at

    receipt = Enum.find(receipts!(ctx, op), &(&1.kind == :delivered))
    assert receipt.webhook_event_id == event.id
    assert receipt.provider_message_id == op.provider_message_id
    assert webhook!(ctx, event).processing_status == :processed

    # A second confirmation (another event id) changes nothing.
    event!("delivered", outcome_body("delivered", op))
    assert Enum.count(receipts!(ctx, op), &(&1.kind == :delivered)) == 1
  end

  test "bounce: accepted → bounced (attention), receipt and a hard_bounce suppression", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    event = event!("bounce", outcome_body("bounce", op))

    op = outreach!(ctx, op)
    assert op.state == :bounced
    {:ok, failure} = Operations.get_failure(op.attention_failure_id, actor: ctx.admin)
    assert failure.class == :delivery_failed
    assert Enum.find(receipts!(ctx, op), &(&1.kind == :bounced)).webhook_event_id == event.id

    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :hard_bounce))

    assert {suppression.delivery_operation_id, suppression.webhook_event_id} ==
             {op.id, event.id}

    assert to_string(suppression.value) == String.downcase(to_string(op.recipient_email))
    assert reload!(ctx, lead).status == :stopped
    assert reload!(ctx, enrollment!(ctx, lead)).stop_reason == :bounced
  end

  test "complaint: a complaint suppression of the recipient", ctx do
    %{delivery: op} = delivered!(ctx)
    event = event!("complaint", outcome_body("complaint", op))

    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :complaint))

    assert {suppression.delivery_operation_id, suppression.webhook_event_id} ==
             {op.id, event.id}
  end

  test "an outcome for an unknown message fails the event for attention", ctx do
    %{delivery: op} = delivered!(ctx)
    event = event!("bounce", outcome_body("bounce", %{op | provider_message_id: "capture-0"}))

    event = webhook!(ctx, event)
    assert event.processing_status == :failed
    {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
    assert failure.class == :validation_error
    assert Enum.filter(suppressions!(ctx), &(&1.reason == :hard_bounce)) == []
  end

  test "a signed delivered event re-routed as bounce or complaint is rejected; nothing suppressed",
       ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    body = outcome_body("delivered", op, id: "evt_retyped_1")

    for type <- ["bounce", "complaint"] do
      assert {:ok, %{status: :rejected, event: event}} = ingest!(type, body)
      assert {event.signature_verdict, event.processing_status} == {:invalid, :rejected}
    end

    assert process!() == %{discard: 0, cancelled: 0, success: 0, failure: 0, snoozed: 0}
    assert outreach!(ctx, op).state == :accepted
    assert Enum.filter(suppressions!(ctx), &(&1.reason in [:hard_bounce, :complaint])) == []
    assert reload!(ctx, lead).status == :in_outreach

    # The re-typed attempts did not pre-claim the id: the real event still lands.
    assert {:ok, %{status: :accepted}} = ingest!("delivered", body)
    assert %{success: 1} = process!()
    assert outreach!(ctx, op).state == :delivered
  end

  test "a valid unsubscribe link suppresses the contact deterministically", ctx do
    %{lead: lead} = delivered!(ctx)
    contact = contact!(ctx, lead)
    event = event!("unsubscribe", unsubscribe_body(contact))

    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_link))
    assert {suppression.scope, suppression.webhook_event_id} == {:email, event.id}
    assert to_string(suppression.value) == String.downcase(to_string(contact.email))
    assert [rule] = decisions_about!(ctx, event.id, :unsubscribe_rule)

    assert {rule.mode, rule.rule_id, rule.outcome} ==
             {:deterministic, "outreach.unsubscribe_link", "unsubscribe"}

    assert reload!(ctx, lead).status == :stopped
  end

  test "a forged unsubscribe token suppresses nothing and fails the event", ctx do
    %{lead: lead} = delivered!(ctx)
    contact = contact!(ctx, lead)
    event = event!("unsubscribe", unsubscribe_body(contact, token: "forged"))

    assert webhook!(ctx, event).processing_status == :failed
    assert Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_link)) == []
    assert reload!(ctx, lead).status == :in_outreach
  end
end

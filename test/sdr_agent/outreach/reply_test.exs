defmodule SdrAgent.Outreach.ReplyTest do
  @moduledoc """
  S9 reply processing (spec §16, S2 Reply): a verified WebhookEvent is
  processed on the `integration` queue into an append-only Reply. A matched
  reply, in one transaction and independent of classification, marks the
  enrollment and lead replied, cancels the enrollment's unsent deliveries
  and open drafts (invalidating their approvals) and records
  `sdr.reply.received`; a deterministic `unsubscribe_rule` Decision decides
  unsubscribe (never the model) and suppresses the recipient. Unmatched
  replies are stored with no side effects; processing is idempotent.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.WebhookWorker
  alias SdrAgent.Sales

  defp delivered!(ctx) do
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    Map.put(approved, :delivery, outreach!(ctx, approved.delivery))
  end

  defp reply!(delivery, text, opts \\ []) do
    assert {:ok, %{status: :accepted, event: event}} =
             ingest!("reply", reply_body(delivery, text, opts))

    assert %{success: 1} = process!()
    event
  end

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  test "a matched reply: Reply stored, enrollment and lead replied, signal recorded", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    text = "Thanks, this sounds interesting. Could we talk next Tuesday?"
    event = reply!(op, text)

    assert [reply] = replies!(ctx)
    assert {reply.match_status, reply.delivery_operation_id} == {:matched, op.id}

    assert {reply.lead_id, reply.enrollment_id, reply.contact_id} ==
             {lead.id, op.enrollment_id, op.recipient_contact_id}

    assert reply.webhook_event_id == event.id
    assert to_string(reply.from_email) == to_string(op.recipient_email)
    assert reply.in_reply_to == message_id_of(op)
    assert reply.body_text == text
    assert reply.body_sha256 == :crypto.hash(:sha256, text)

    assert reload!(ctx, enrollment!(ctx, lead)).status == :replied
    assert reload!(ctx, lead).status == :replied
    assert {:ok, [handoff]} = Sales.list_handoff_queue(actor: ctx.admin)
    assert handoff.id == lead.id

    event = webhook!(ctx, event)

    assert {event.processing_status, is_struct(event.processed_at, DateTime)} ==
             {:processed, true}

    assert [%{actor_type: :webhook_ingestor}] =
             events_of_type(ctx.tenant, "outreach.reply.received")

    assert [signal] = events_of_type(ctx.tenant, "sdr.reply.received")
    assert {signal.category, signal.actor_type} == {:signal, :webhook_ingestor}
    assert signal.payload["data"]["reply_id"] == reply.id

    assert [rule] = decisions_about!(ctx, reply.id, :unsubscribe_rule)

    assert {rule.mode, rule.outcome, rule.rule_id} ==
             {:deterministic, "none", "outreach.unsubscribe_rule"}

    assert Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply)) == []
  end

  test "a reply cancels the enrollment's unsent delivery, its draft and approval", ctx do
    %{delivery: first} = drafted = delivered!(ctx)
    followup = followup_draft!(ctx, drafted)
    approval = approve!(ctx, followup, operator!(ctx, :reviewer))
    pending = delivery_of!(ctx, approval)
    assert pending.state == :pending

    reply!(first, "Got it, thanks.")

    assert outreach!(ctx, pending).state == :cancelled
    assert draft!(ctx, followup).status == :cancelled
    approval = outreach!(ctx, approval)
    assert {approval.status, approval.invalidated_reason} == {:invalidated, :campaign_closed}

    # The cancelled delivery's job finds nothing to send.
    assert %{success: 1} = deliver!()
    assert outreach!(ctx, pending).state == :cancelled
  end

  test "a reply cancels a follow-up draft still in review", ctx do
    %{delivery: first} = drafted = delivered!(ctx)
    followup = followup_draft!(ctx, drafted)
    assert followup.status == :pending_review

    reply!(first, "Not right now.")
    assert draft!(ctx, followup).status == :cancelled
  end

  test "after a reply the scheduled follow-up records stop", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    due = enrollment!(ctx, lead).next_step_due_at
    reply!(op, "Thanks!")

    Clock.freeze(due)

    assert %{success: 1} =
             Oban.drain_queue(queue: :followup, with_safety: false, with_scheduled: true)

    assert [%{outcome: "stop"}] =
             decisions_about!(ctx, enrollment!(ctx, lead).id, :followup_next_step)

    assert events_of_type(ctx.tenant, "sdr.followup.due") == []
  end

  test "an unsubscribe reply is suppressed by the deterministic rule", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    event = reply!(op, "Please remove me from your list.\n\nUnsubscribe.")

    assert [reply] = replies!(ctx)
    assert [rule] = decisions_about!(ctx, reply.id, :unsubscribe_rule)
    assert {rule.mode, rule.outcome} == {:deterministic, "unsubscribe"}
    assert rule.model_invocation_id == nil

    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))

    assert {suppression.scope, to_string(suppression.value)} ==
             {:email, String.downcase(to_string(op.recipient_email))}

    assert {suppression.decision_id, suppression.reply_id, suppression.webhook_event_id} ==
             {rule.id, reply.id, event.id}

    assert reload!(ctx, lead).status == :stopped
    assert reload!(ctx, enrollment!(ctx, lead)).status == :replied
    assert webhook!(ctx, event).processing_status == :processed
  end

  test "an unmatched reply is stored and surfaced with no side effects", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)

    reply!(op, "Who is this?",
      from: "stranger@unknown.example.test",
      in_reply_to: "<nothing@elsewhere.example.test>"
    )

    assert [reply] = replies!(ctx)

    assert {reply.match_status, reply.delivery_operation_id, reply.lead_id} ==
             {:unmatched, nil, nil}

    assert reload!(ctx, lead).status == :in_outreach
    assert reload!(ctx, enrollment!(ctx, lead)).status == :active
    assert events_of_type(ctx.tenant, "sdr.reply.received") == []
  end

  test "a reply without In-Reply-To matches the latest delivery to its sender", ctx do
    %{delivery: op} = delivered!(ctx)
    reply!(op, "Replying from my phone.", in_reply_to: nil)
    assert [%{match_status: :matched, delivery_operation_id: id}] = replies!(ctx)
    assert id == op.id
  end

  test "processing is idempotent: a re-run job changes nothing", ctx do
    %{delivery: op} = delivered!(ctx)
    event = reply!(op, "Interested.")

    assert :ok =
             perform_job(WebhookWorker, %{
               "webhook_event_id" => event.id,
               "tenant_id" => ctx.tenant.id
             })

    assert [_reply] = replies!(ctx)
    assert [_] = events_of_type(ctx.tenant, "outreach.reply.received")
  end

  test "a payload that fails its shape fails the event with an attention Failure", ctx do
    body = ~s({"id":"evt_bad_1","type":"reply","data":{"text":"no sender"}})
    assert {:ok, %{status: :accepted, event: event}} = ingest!("reply", body)
    assert %{success: 1} = process!()

    event = webhook!(ctx, event)
    assert event.processing_status == :failed
    {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
    assert {failure.class, failure.subject_id} == {:validation_error, event.id}
    assert replies!(ctx) == []
  end

  test "WebhookEvents and Replies are written only by the webhook ingestor", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             WebhookEvent
             |> Ash.Changeset.for_create(
               :receive,
               %{
                 provider: :capture_sim,
                 event_type: :reply,
                 external_event_id: "x",
                 raw_body_sha256: :crypto.hash(:sha256, "x")
               },
               actor: ctx.admin
             )
             |> Ash.create()

    assert {:error, %Ash.Error.Forbidden{}} =
             Outreach.Reply
             |> Ash.Changeset.for_create(
               :receive,
               %{
                 webhook_event_id: Ecto.UUID.generate(),
                 message_id: "<x@example.test>",
                 from_email: "a@example.test",
                 to_email: "b@example.test",
                 body_text: "x"
               },
               actor: ctx.admin
             )
             |> Ash.create()

    assert {:ok, _} = Outreach.list_records(Outreach.Reply, actor: operator!(ctx, :auditor))
  end
end

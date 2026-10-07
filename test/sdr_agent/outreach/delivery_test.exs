defmodule SdrAgent.Outreach.DeliveryTest do
  @moduledoc """
  S8b outbox delivery (spec §14): a granted approval inserts its
  DeliveryOperation and delivery job in the same transaction; the delivery
  worker claims it through one deterministic send gate (consuming the
  approval and a SendQuotaDay unit), renders the exact RFC 5322 message with
  footer and unsubscribe link, hands it to the local capture adapter (the
  only adapter), records acceptance with receipts, marks the draft sent and
  advances the enrollment in the campaign time zone.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.Unsubscribe
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  test "a grant inserts its DeliveryOperation and delivery job in one transaction", ctx do
    %{approval: approval, delivery: op, draft: draft, revision: rev} = approved!(ctx)

    assert op.state == :pending
    assert op.idempotency_key == "delivery:#{approval.id}"

    assert {op.draft_id, op.draft_revision_id, op.enrollment_id} ==
             {draft.id, rev.id, draft.enrollment_id}

    assert {op.campaign_id, op.recipient_contact_id} ==
             {draft.campaign_id, draft.recipient_contact_id}

    assert op.revision_content_sha256 == approval.revision_content_sha256
    assert op.recipient_email == approval.recipient_email
    assert {op.provider, op.attempt_count, op.max_attempts} == {:capture, 0, 3}
    assert op.requested_at

    assert_enqueued(
      worker: SdrAgent.Outreach.DeliveryWorker,
      queue: :delivery,
      args: %{"delivery_operation_id" => op.id, "tenant_id" => ctx.tenant.id}
    )

    assert [_] = events_of_type(ctx.tenant, "outreach.delivery.requested")
  end

  test "the worker claims, renders, captures and records acceptance", ctx do
    %{approval: approval, delivery: op, draft: draft, lead: lead, revision: rev} = approved!(ctx)
    contact = contact!(ctx, lead)

    assert %{success: 1} = deliver!()

    op = outreach!(ctx, op)
    assert {op.state, op.attempt_count} == {:accepted, 1}
    assert "capture-" <> _ = op.provider_message_id
    assert op.send_quota_date == ~D[2026-01-06]
    assert op.footer_template_version == "footer/1"
    assert op.attempting_at && op.accepted_at

    assert outreach!(ctx, approval).status == :consumed
    assert draft!(ctx, draft).status == :sent

    assert [:captured, :accepted] = Enum.map(receipts!(ctx, op), & &1.kind)

    for receipt <- receipts!(ctx, op) do
      assert {receipt.provider_message_id, receipt.rendered_sha256, receipt.idempotency_key} ==
               {op.provider_message_id, op.rendered_sha256, op.idempotency_key}
    end

    [gate] = decisions_about!(ctx, op.id, :send_gate)
    assert {gate.mode, gate.outcome, gate.id} == {:deterministic, "pass", op.last_decision_id}
    assert [%{outcome: "reserved"}] = decisions_about!(ctx, op.id, :quota_check)

    {:ok, [day]} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)

    assert {day.local_date, day.timezone, day.cap, day.consumed} ==
             {~D[2026-01-06], "America/Denver", 25, 1}

    {:ok, rendered} = SdrAgent.Audit.read_content(op.rendered_sha256, actor: ctx.admin)
    url = Unsubscribe.url(ctx.tenant.id, contact.id)

    assert url ==
             "https://sdr.example.test/unsubscribe/" <>
               Unsubscribe.token(ctx.tenant.id, contact.id)

    assert rendered =~ "From: Demo SDR <sdr@example.test>\r\n"
    assert rendered =~ "To: #{contact.email}\r\n"
    assert rendered =~ "Subject: #{rev.subject}\r\n"
    assert rendered =~ "List-Unsubscribe: <#{url}>\r\n"
    assert rendered =~ String.replace(rev.body_text, "\n", "\r\n")
    assert rendered =~ "Unsubscribe: #{url}"
    refute rendered =~ ~r/[^\r]\n/
    assert :crypto.hash(:sha256, rendered) == op.rendered_sha256

    enrollment = enrollment!(ctx, lead)
    assert enrollment.current_step_position == 1
    assert enrollment.next_step_due_at == ~U[2026-01-09 15:00:00.000000Z]

    assert_enqueued(
      worker: SdrAgent.SDR.FollowupWorker,
      queue: :followup,
      args: %{
        "enrollment_id" => enrollment.id,
        "tenant_id" => ctx.tenant.id,
        "step_position" => 1
      },
      scheduled_at: enrollment.next_step_due_at
    )

    for type <-
          ~w(outreach.delivery.claimed outreach.delivery.accepted outreach.delivery.receipt_recorded
                   outreach.approval.consumed outreach.draft.sent sales.enrollment.step_advanced) do
      assert [_ | _] = events_of_type(ctx.tenant, type), type
    end

    assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.aud)
  end

  test "a second job for the same delivery does nothing; the capture is idempotent on the key",
       ctx do
    %{delivery: op} = approved!(ctx)
    assert %{success: 1} = deliver!()
    accepted = outreach!(ctx, op)

    {:ok, _job} =
      %{"delivery_operation_id" => op.id, "tenant_id" => ctx.tenant.id}
      |> SdrAgent.Outreach.DeliveryWorker.new()
      |> Oban.insert()

    assert %{success: 1} = deliver!()
    again = outreach!(ctx, op)

    assert {again.state, again.attempt_count, again.updated_at} ==
             {:accepted, 1, accepted.updated_at}

    {:ok, rendered} = SdrAgent.Audit.read_content(accepted.rendered_sha256, actor: ctx.admin)

    assert {:ok, %{provider_message_id: pmid}} =
             Delivery.CaptureAdapter.deliver(again, rendered,
               actor: Actor.system(:delivery_worker, ctx.tenant.id)
             )

    assert pmid == accepted.provider_message_id
    assert [:captured, :accepted] = Enum.map(receipts!(ctx, op), & &1.kind)
  end

  test "header values cannot inject headers", ctx do
    %{draft: draft, revision: rev} = drafted!(ctx)

    {:ok, edited} =
      Outreach.edit_draft(
        draft,
        %{subject: "Hi\r\nBcc: someone@example.test", body_text: rev.body_text},
        actor: operator!(ctx, :reviewer)
      )

    approval = approve!(ctx, edited, ctx.admin)
    assert %{success: 1} = deliver!()
    op = delivery_of!(ctx, approval)
    {:ok, rendered} = SdrAgent.Audit.read_content(op.rendered_sha256, actor: ctx.admin)
    [headers, _body] = String.split(rendered, "\r\n\r\n", parts: 2)
    refute headers =~ ~r/^Bcc:/m
    assert headers =~ "Subject: Hi  Bcc: someone@example.test\r\n"
  end

  describe "enrollment step advancement" do
    test "advances in the campaign time zone across DST and completes after the last step", ctx do
      %{lead: lead} = drafted!(ctx)
      enrollment = enrollment!(ctx, lead)
      dlv = Actor.system(:delivery_worker, ctx.tenant.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.advance_enrollment(
                 enrollment,
                 %{step_position: 1, accepted_at: ~U[2026-10-30 16:00:00Z]},
                 actor: operator!(ctx, :reviewer)
               )

      assert {:ok, advanced} =
               Sales.advance_enrollment(
                 enrollment,
                 %{step_position: 1, accepted_at: ~U[2026-10-30 16:00:00Z]},
                 actor: dlv
               )

      # 2026-10-30 10:00 MDT + 3 local days = 2026-11-02 10:00 MST
      assert {advanced.status, advanced.current_step_position, advanced.next_step_due_at} ==
               {:active, 1, ~U[2026-11-02 17:00:00.000000Z]}

      assert {:ok, completed} =
               Sales.advance_enrollment(
                 advanced,
                 %{step_position: 2, accepted_at: ~U[2026-11-03 16:00:00Z]},
                 actor: dlv
               )

      assert {completed.status, completed.current_step_position, completed.next_step_due_at} ==
               {:completed, 2, nil}

      assert F.declared(Sales.CampaignEnrollment) ==
               F.transition_actions(Sales.CampaignEnrollment)
    end

    test "delivery, reconciler and scheduler read what the send gate needs", ctx do
      %{lead: lead, draft: draft} = drafted!(ctx)

      for type <- [:delivery_worker, :reconciler, :scheduler] do
        actor = Actor.system(type, ctx.tenant.id)
        assert {:ok, _} = Sales.fetch(Sales.Lead, lead.id, actor: actor), "#{type} lead"

        assert {:ok, _} = Sales.fetch(Sales.Contact, lead.contact_id, actor: actor),
               "#{type} contact"

        assert {:ok, _} = Sales.fetch(Sales.Campaign, ctx.campaign_id, actor: actor),
               "#{type} campaign"

        assert {:ok, _} = Sales.fetch(Sales.CampaignEnrollment, draft.enrollment_id, actor: actor)
        assert {:ok, _} = Sales.fetch(Sales.SequenceStep, draft.sequence_step_id, actor: actor)
      end
    end
  end

  describe "lifecycle and immutability" do
    test "the declared transition table matches the actions" do
      assert F.declared(DeliveryOperation) == F.transition_actions(DeliveryOperation)
      assert F.declared(Outreach.Approval) == F.transition_actions(Outreach.Approval)
      assert F.declared(Outreach.Draft) == F.transition_actions(Outreach.Draft)
    end

    test "receipts are append-only; binding columns and terminal deliveries are frozen", ctx do
      %{delivery: op} = approved!(ctx)
      id = Ecto.UUID.dump!(op.id)
      binding = "UPDATE delivery_operations SET recipient_email = 'x@example.test' WHERE id = $1"

      assert {:error, %Postgrex.Error{}} = raw_error(binding, [id])
      assert %{success: 1} = deliver!()
      assert {:error, %Postgrex.Error{}} = raw_error(binding, [id])

      assert {:error, %Postgrex.Error{}} =
               raw_error("UPDATE delivery_receipts SET provider_message_id = 'x'")

      assert {:error, %Postgrex.Error{}} =
               raw_error("DELETE FROM delivery_operations WHERE id = $1", [id])

      %{approval: second, delivery: pending} = approved!(ctx, "02")
      {:ok, _} = Outreach.revoke(second, actor: ctx.admin)
      assert outreach!(ctx, pending).state == :cancelled

      assert {:error, %Postgrex.Error{}} =
               raw_error("UPDATE delivery_operations SET state = 'pending' WHERE id = $1", [
                 Ecto.UUID.dump!(pending.id)
               ])
    end
  end
end

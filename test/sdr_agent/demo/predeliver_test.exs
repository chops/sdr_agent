defmodule SdrAgent.Demo.PredeliverTest do
  @moduledoc """
  `bin/demo predeliver`: fixture lead 01 run to a draft awaiting review, or —
  with an explicit approval as the demo reviewer, bound to the displayed
  recipient — to a captured email; the send gate (quiet hours) still
  applies; idempotent.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Clock
  alias SdrAgent.Demo.Predeliver

  test "without approval the lead is researched and drafted, and waits for a human", ctx do
    assert {:ok, %{stage: :awaiting_review, draft_id: draft_id, delivery: nil}} =
             Predeliver.run()

    assert draft!(ctx, %{id: draft_id}).status == :pending_review
    assert approvals!(ctx, %{id: draft_id}) == []
    assert fixture_lead!(ctx, "01").status == :in_outreach
  end

  test "with approval: bound to the displayed recipient, by the demo reviewer, captured", ctx do
    assert {:ok, %{stage: :captured, draft_id: draft_id, delivery: delivery}} =
             Predeliver.run(approve: true)

    reviewer = user!(ctx, :reviewer)
    contact = contact!(ctx, fixture_lead!(ctx, "01"))
    [approval] = approvals!(ctx, %{id: draft_id})

    assert approval.approver_id == reviewer.id
    assert to_string(approval.recipient_email) == to_string(contact.email)
    assert delivery.state == :accepted
    assert [%{kind: :captured}] = Enum.filter(receipts!(ctx, delivery), &(&1.kind == :captured))
    assert draft!(ctx, %{id: draft_id}).status == :sent
    assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.aud)
  end

  test "a re-run reports the same stage and writes nothing but its sign-in record", ctx do
    {:ok, first} = Predeliver.run(approve: true)
    before = length(events(ctx.tenant))

    assert {:ok, again} = Predeliver.run(approve: true)
    assert {again.stage, again.draft_id} == {:captured, first.draft_id}

    assert ctx.tenant |> events() |> Enum.drop(before) |> Enum.map(& &1.event_type) ==
             ["auth.sign_in.succeeded"]
  end

  test "inside quiet hours the send gate defers the approved delivery", _ctx do
    # 19:30 America/Denver (01:30 UTC next day, MDT) — inside 18:00–08:00.
    Clock.freeze(~U[2026-10-08 01:30:00Z])

    assert {:ok, %{stage: :deferred, delivery: delivery}} = Predeliver.run(approve: true)
    assert delivery.state == :pending
    assert DateTime.compare(delivery.not_before, Clock.utc_now()) == :gt
  end
end

defmodule SdrAgent.Demo.PredeliverUnseededTest do
  @moduledoc "`bin/demo predeliver` on a database without the demo data set."
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Demo.Predeliver

  test "refuses with :not_seeded and writes nothing" do
    assert Predeliver.run(approve: true) == {:error, :not_seeded}
  end
end

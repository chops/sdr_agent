defmodule SdrAgent.Outreach.DeliveryGateTest do
  @moduledoc """
  S8b send gate: one deterministic `send_gate` Decision per evaluation.
  Quiet hours (18:00–08:00 campaign time) and the 25/day tenant cap defer a
  delivery with `not_before`; any other failure — approval no longer
  granted, recipient email changed, suppression, enrollment or campaign not
  active — cancels it and invalidates the approval. Revoke cancels a pending
  delivery and nothing after the claim; `cancel_retry` stops a retryable one.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  defp gate_outcomes(ctx, op),
    do: Enum.map(decisions_about!(ctx, op.id, :send_gate), & &1.outcome)

  test "quiet hours defer the send to 08:00 campaign time, then it goes out", ctx do
    %{delivery: op, approval: approval} = approved!(ctx)
    # 2026-01-06 19:00 MST
    Clock.freeze(~U[2026-01-07 02:00:00.000000Z])

    assert %{success: 1} = deliver!()
    deferred = outreach!(ctx, op)
    assert {deferred.state, deferred.not_before} == {:pending, ~U[2026-01-07 15:00:00.000000Z]}
    assert gate_outcomes(ctx, op) == ["defer_quiet_hours"]
    assert outreach!(ctx, approval).status == :granted
    assert receipts!(ctx, op) == []

    assert_enqueued(
      worker: SdrAgent.Outreach.DeliveryWorker,
      args: %{"delivery_operation_id" => op.id},
      scheduled_at: ~U[2026-01-07 15:00:00.000000Z]
    )

    Clock.freeze(~U[2026-01-07 15:00:00.000000Z])
    assert %{success: 1} = deliver!()
    assert outreach!(ctx, op).state == :accepted
    assert gate_outcomes(ctx, op) == ["defer_quiet_hours", "pass"]
  end

  test "the daily cap defers to the next local midnight; retries never consume", ctx do
    put_env!(:daily_send_cap, 1)
    %{delivery: first} = approved!(ctx, "01")
    %{delivery: second} = approved!(ctx, "02")

    assert %{success: 2} = deliver!()
    states = Enum.map([first, second], &outreach!(ctx, &1)) |> Enum.sort_by(& &1.state)
    assert [%{state: :accepted}, %{state: :pending} = waiting] = states
    assert waiting.not_before == ~U[2026-01-07 07:00:00.000000Z]
    assert List.last(gate_outcomes(ctx, waiting)) == "defer_quota"
    assert [%{outcome: "exhausted"}] = decisions_about!(ctx, waiting.id, :quota_check)

    {:ok, [day]} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)
    assert {day.local_date, day.cap, day.consumed} == {~D[2026-01-06], 1, 1}

    Clock.freeze(~U[2026-01-07 15:00:00.000000Z])
    assert %{success: 1} = deliver!()
    assert outreach!(ctx, waiting).state == :accepted
    assert outreach!(ctx, waiting).send_quota_date == ~D[2026-01-07]
  end

  test "the cap can only be lowered, never raised above 25" do
    put_env!(:daily_send_cap, 500)
    assert Outreach.Compliance.daily_send_cap() == 25
    put_env!(:daily_send_cap, 3)
    assert Outreach.Compliance.daily_send_cap() == 3
    assert Outreach.Compliance.timezone() == "America/Denver"
  end

  test "a changed recipient email cancels the delivery and invalidates the approval", ctx do
    %{delivery: op, approval: approval, draft: draft, lead: lead} = approved!(ctx)
    contact = contact!(ctx, lead)

    {:ok, _} =
      Sales.update(contact, :change_email, %{email: "new.person@brightpath-freight.test"},
        actor: ctx.admin
      )

    assert %{success: 1} = deliver!()
    cancelled = outreach!(ctx, op)
    assert {cancelled.state, cancelled.last_error["reason"]} == {:cancelled, "recipient_changed"}
    assert gate_outcomes(ctx, op) == ["refuse"]

    invalidated = outreach!(ctx, approval)

    assert {invalidated.status, invalidated.invalidated_reason} ==
             {:invalidated, :recipient_changed}

    assert draft!(ctx, draft).status == :cancelled
    assert receipts!(ctx, op) == []
  end

  test "a paused campaign cancels the delivery (campaign_closed)", ctx do
    %{delivery: op, approval: approval} = approved!(ctx)
    {:ok, campaign} = Sales.fetch(Sales.Campaign, ctx.campaign_id, actor: ctx.admin)
    {:ok, _} = SdrAgent.SDR.pause_campaign(campaign, actor: ctx.admin)

    assert %{success: 1} = deliver!()
    assert outreach!(ctx, op).state == :cancelled
    assert outreach!(ctx, approval).invalidated_reason == :campaign_closed
  end

  test "a suppression after approval cancels the pending delivery at once", ctx do
    %{delivery: op, approval: approval, draft: draft, lead: lead} = approved!(ctx)
    email = to_string(contact!(ctx, lead).email)
    {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    assert outreach!(ctx, op).state == :cancelled
    assert outreach!(ctx, approval).status == :invalidated
    assert draft!(ctx, draft).status == :cancelled
    assert %{success: 1} = deliver!()
    assert receipts!(ctx, op) == []
  end

  test "revoke cancels a pending delivery; after the claim only the delivery can be stopped",
       ctx do
    %{delivery: op, approval: approval, draft: draft} = approved!(ctx)
    {:ok, revoked} = Outreach.revoke(approval, actor: ctx.admin)
    assert revoked.status == :revoked
    assert outreach!(ctx, op).state == :cancelled
    assert draft!(ctx, draft).status == :pending_review
    assert %{success: 1} = deliver!()
    assert receipts!(ctx, op) == []

    %{approval: claimed} = approved!(ctx, "02")
    assert %{success: 1} = deliver!()
    assert outreach!(ctx, claimed).status == :consumed

    assert {:error, %Ash.Error.Invalid{}} =
             Outreach.revoke(outreach!(ctx, claimed), actor: ctx.admin)
  end

  test "cancel_retry stops a retryable delivery; auditors and agents are refused", ctx do
    start_supervised!(SdrAgent.Test.CaptureFaults)
    put_env!(:capture_faults, SdrAgent.Test.CaptureFaults)
    SdrAgent.Test.CaptureFaults.plan(:before_capture, [{:error, {:retryable, :rate_limited}}])
    %{delivery: op, draft: draft} = approved!(ctx)

    assert %{success: 1} = deliver!()
    retryable = outreach!(ctx, op)
    assert {retryable.state, retryable.attempt_count} == {:failed_retryable, 1}
    assert retryable.last_error["reason"] == "rate_limited"

    before = length(events_of_type(ctx.tenant, "authz.denied"))

    for actor <- [operator!(ctx, :auditor), ctx.agent] do
      assert {:error, %Ash.Error.Forbidden{}} = Outreach.cancel_retry(retryable, actor: actor)
    end

    assert length(events_of_type(ctx.tenant, "authz.denied")) == before + 2

    assert {:ok, cancelled} = Outreach.cancel_retry(retryable, actor: operator!(ctx, :reviewer))
    assert cancelled.state == :cancelled
    assert draft!(ctx, draft).status == :cancelled
    assert %{success: 1} = deliver!()
    assert [] = Enum.filter(receipts!(ctx, op), &(&1.kind == :captured))
  end
end

defmodule SdrAgent.Inbox.ContinuationHistoryTest do
  @moduledoc "C1 keyset mutation boundaries, truthful recovery and committed capture history."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Sales
  alias SdrAgent.Test.CaptureFaults
  alias SdrAgent.WebhookFixtures

  test "resolving the cursor's last returned row does not skip the next tied row", ctx do
    failures = for _ <- 1..4, do: failure!(ctx)
    [first | rest] = Enum.sort_by(failures, & &1.id)
    session = session!(ctx.admin)
    assert {:ok, page} = refresh(session, limit: 1)
    assert Enum.map(page.items, & &1.subject_ref.id) == [first.id]

    assert {:ok, _} =
             Operations.resolve_failure(first, %{resolution_note: "Synthetic repair"},
               actor: ctx.admin
             )

    assert {:ok, continued} = refresh(session, cursor: page.next_cursor)
    assert Enum.map(continued.items, & &1.subject_ref.id) == Enum.map(rest, & &1.id)
    assert total!(continued, :live_failures) == 3
    assert continued.next_cursor == nil
  end

  test "new critical work before the cursor appears on refresh, not duplicated in continuation",
       ctx do
    failures = for _ <- 1..3, do: failure!(ctx)
    [first | rest] = Enum.sort_by(failures, & &1.id)
    session = session!(ctx.admin)
    assert {:ok, page} = refresh(session, limit: 1)
    assert Enum.map(page.items, & &1.subject_ref.id) == [first.id]
    Clock.freeze(DateTime.add(Clock.utc_now(), 1, :second))
    critical = failure!(ctx, %{severity: :critical})

    assert {:ok, continued} = refresh(session, cursor: page.next_cursor)
    assert Enum.map(continued.items, & &1.subject_ref.id) == Enum.map(rest, & &1.id)
    assert total!(continued, :live_failures) == 4
    assert {:ok, fresh} = refresh(session)
    assert hd(fresh.items).subject_ref.id == critical.id
  end

  test "unknown capture is not counted until reconciliation commits its acceptance", ctx do
    start_supervised!(CaptureFaults)
    OutreachFixtures.put_env!(:capture_faults, CaptureFaults)
    CaptureFaults.plan(:after_capture, [{:error, {:unknown, :timeout}}])
    %{delivery: delivery} = OutreachFixtures.approved!(ctx)
    assert %{success: 1} = OutreachFixtures.deliver!()
    assert OutreachFixtures.outreach!(ctx, delivery).state == :unknown
    session = session!(ctx.admin)

    assert {:ok, before} = refresh(session)
    assert total!(before, :local_captures_this_week) == 0
    assert total!(before, :live_failures) == 1
    refute Enum.any?(before.items, &(&1.subject_ref.id == delivery.id))

    assert %{success: 1} = OutreachFixtures.reconcile!()
    assert OutreachFixtures.outreach!(ctx, delivery).accepted_at
    assert {:ok, after_reconcile} = refresh(session)
    assert total!(after_reconcile, :local_captures_this_week) == 1
    assert total!(after_reconcile, :live_failures) == 0
    assert after_reconcile.items == []
  end

  for outcome <- ["delivered", "bounce"] do
    test "later #{outcome} does not erase a committed local capture", ctx do
      %{delivery: delivery} = OutreachFixtures.approved!(ctx)
      assert %{success: 1} = OutreachFixtures.deliver!()
      accepted = OutreachFixtures.outreach!(ctx, delivery)
      assert accepted.accepted_at
      body = WebhookFixtures.outcome_body(unquote(outcome), accepted)

      assert {:ok, %{status: :accepted}} = WebhookFixtures.ingest!(unquote(outcome), body)
      assert %{success: 1} = WebhookFixtures.process!()
      terminal = OutreachFixtures.outreach!(ctx, delivery)
      assert terminal.state in [:delivered, :bounced]
      assert terminal.accepted_at == accepted.accepted_at
      session = session!(ctx.admin)

      assert {:ok, page} = refresh(session)
      assert total!(page, :local_captures_this_week) == 1
      assert total!(page, :pending_email_drafts) == 0
      refute Enum.any?(page.items, &(&1.subject_ref.id == delivery.id))
    end
  end

  test "acceptance exactly at Monday start is included without a pending history row", ctx do
    # A real domain-created campaign whose quiet hours do not cover midnight;
    # neither stale approval nor the default quiet-hours deferral hides the edge.
    attrs =
      SdrAgent.Demo.Fixtures.campaign()
      |> Map.take([
        :icp_definition_id,
        :sequence_id,
        :sender_name,
        :sender_email,
        :timezone,
        :footer_template_version
      ])
      |> Map.merge(%{
        name: "Synthetic midnight boundary",
        quiet_hours_start: ~T[01:00:00],
        quiet_hours_end: ~T[02:00:00]
      })

    assert {:ok, campaign} = Sales.create_campaign(attrs, actor: ctx.admin)
    assert {:ok, campaign} = Sales.update(campaign, :activate, %{}, actor: ctx.admin)
    Clock.freeze(~U[2026-01-12 07:00:00.000000Z])
    %{delivery: delivery} = OutreachFixtures.approved!(%{ctx | campaign_id: campaign.id})
    assert %{success: 1} = OutreachFixtures.deliver!()
    assert OutreachFixtures.outreach!(ctx, delivery).accepted_at == Clock.utc_now()
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert total!(page, :local_captures_this_week) == 1
    assert total!(page, :pending_email_drafts) == 0
    assert page.items == []
    assert page.totals.local_captures_this_week.week_start_utc == Clock.utc_now()
  end

  test "unknown agent outcome stays inspectable but never offers an enabled blind retry", ctx do
    %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant)

    assert {:ok, reserved} =
             Agents.reserve_model_invocation(
               run,
               AgentsFixtures.model_attrs("inbox-unknown"),
               actor: agent
             )

    assert {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    assert {:ok, unknown} = Agents.mark_model_invocation_unknown(sent, actor: agent)
    assert unknown.status == :unknown

    assert {:ok, stopped} =
             Agents.fail_run(
               run,
               %{status_reason: :provider_error, failure_reason: "Synthetic unknown outcome"},
               actor: agent
             )

    # The actual sent/unknown ledger entry, not a forged Failure flag,
    # prevents treating this as a known-safe blind retry.
    assert {:ok, failure} = Operations.get_failure(stopped.attention_failure_id, actor: ctx.admin)
    session = session!(ctx.admin)
    assert {:ok, page} = refresh(session)
    row = item!(page, failure)
    assert Enum.any?(row.actions, &(&1.action_id == :inspect))
    refute Enum.any?(row.actions, &(&1.action_id == :retry_run and &1.availability == :enabled))
  end
end

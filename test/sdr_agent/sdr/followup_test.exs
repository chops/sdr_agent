defmodule SdrAgent.SDR.FollowupTest do
  @moduledoc """
  The S8b follow-up schedule (checklist 1.7): an accepted first touch
  advances the enrollment and schedules one `followup` job at its due time
  in the campaign time zone. At due time the scheduler records a
  deterministic `followup_next_step` Decision and emits `sdr.followup.due`
  for an enrollment still active at that step; anything else is a recorded
  `stop`. (Drafting the follow-up is the agent route S9 adds.)
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Outreach

  defp followups!, do: Oban.drain_queue(queue: :followup, with_safety: false, with_scheduled: true)

  test "at due time an active enrollment gets a draft_followup decision and sdr.followup.due", ctx do
    %{lead: lead} = approved!(ctx)
    assert %{success: 1} = deliver!()
    enrollment = enrollment!(ctx, lead)

    Clock.freeze(enrollment.next_step_due_at)
    assert %{success: 1} = followups!()

    assert [decision] = decisions_about!(ctx, enrollment.id, :followup_next_step)
    assert {decision.mode, decision.outcome} == {:deterministic, "draft_followup"}

    assert [event] = events_of_type(ctx.tenant, "sdr.followup.due")
    assert event.category == :signal
    assert event.payload["data"]["enrollment_id"] == enrollment.id
    assert event.actor_type == :scheduler
  end

  test "an enrollment stopped before the due time records stop and emits nothing", ctx do
    %{lead: lead} = approved!(ctx)
    assert %{success: 1} = deliver!()
    enrollment = enrollment!(ctx, lead)
    email = to_string(contact!(ctx, lead).email)
    {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    Clock.freeze(enrollment.next_step_due_at)
    assert %{success: 1} = followups!()
    assert [%{outcome: "stop"}] = decisions_about!(ctx, enrollment.id, :followup_next_step)
    assert events_of_type(ctx.tenant, "sdr.followup.due") == []
  end

  test "a job run before the due time waits", ctx do
    %{lead: lead} = approved!(ctx)
    assert %{success: 1} = deliver!()
    enrollment = enrollment!(ctx, lead)

    assert %{snoozed: 1} = followups!()
    assert decisions_about!(ctx, enrollment.id, :followup_next_step) == []
  end
end

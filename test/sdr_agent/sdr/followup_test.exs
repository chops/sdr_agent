defmodule SdrAgent.SDR.FollowupTest do
  @moduledoc """
  The S8b follow-up schedule (checklist 1.7): an accepted first touch
  advances the enrollment and schedules one `followup` job at its due time
  in the campaign time zone. At due time the scheduler records a
  deterministic `followup_next_step` Decision and emits `sdr.followup.due`
  for an enrollment still active at that step; anything else is a recorded
  `stop`. (Drafting the follow-up is the agent route S9 adds.)

  The follow-up switch (`config :sdr_agent, :follow_ups`; D-218 item 9, the
  hosted containment): only `:enabled` (dev, test) lets follow-ups run. Off
  (`:disabled` in prod, or missing), an accepted first touch schedules no
  follow-up job and a queued one is cancelled before any decision, each with
  a logged refusal.
  """
  use SdrAgent.SDRCase, async: false

  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.SDR.FollowupWorker

  defp followups!,
    do: Oban.drain_queue(queue: :followup, with_safety: false, with_scheduled: true)

  # Removes the follow-up setting for the rest of the test.
  defp delete_follow_ups_env! do
    previous = Application.fetch_env(:sdr_agent, :follow_ups)
    Application.delete_env(:sdr_agent, :follow_ups)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :follow_ups, value)
        :error -> Application.delete_env(:sdr_agent, :follow_ups)
      end
    end)
  end

  describe "the follow-up switch" do
    test "disabled: an accepted first touch schedules no follow-up job (refusal logged)", ctx do
      put_env!(:follow_ups, :disabled)
      %{lead: lead} = approved!(ctx)
      log = capture_log(fn -> assert %{success: 1} = deliver!() end)

      assert all_enqueued(worker: FollowupWorker) == []
      assert log =~ "follow-up scheduling refused: follow-ups are disabled"
      assert enrollment!(ctx, lead).current_step_position == 1
    end

    test "missing: counts as disabled (fail closed)", ctx do
      delete_follow_ups_env!()
      %{lead: _lead} = approved!(ctx)
      log = capture_log(fn -> assert %{success: 1} = deliver!() end)

      assert all_enqueued(worker: FollowupWorker) == []
      assert log =~ "follow-up scheduling refused: follow-ups are disabled"
    end

    test "disabled: a queued follow-up job is cancelled before any decision or signal", ctx do
      %{lead: lead} = approved!(ctx)
      assert %{success: 1} = deliver!()
      enrollment = enrollment!(ctx, lead)
      assert length(all_enqueued(worker: FollowupWorker)) == 1

      put_env!(:follow_ups, :disabled)
      Clock.freeze(enrollment.next_step_due_at)
      log = capture_log(fn -> send(self(), {:drained, followups!()}) end)
      assert_received {:drained, drained}

      assert {drained.cancelled, drained.success} == {1, 0}
      assert decisions_about!(ctx, enrollment.id, :followup_next_step) == []
      assert events_of_type(ctx.tenant, "sdr.followup.due") == []
      assert log =~ "follow-up execution refused: follow-ups are disabled"
    end
  end

  test "at due time an active enrollment gets a draft_followup decision and sdr.followup.due",
       ctx do
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

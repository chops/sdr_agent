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

  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR.FollowupWorker

  # The error-only lookup seam of test-seam builds (plan r3 §3 item 5).
  @lookup_fault :followup_lookup_fault

  defp followups!,
    do: Oban.drain_queue(queue: :followup, with_safety: false, with_scheduled: true)

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

  # Suppression safety fix, defect A (plan r3 §1 A, §6 W1–W4): the scheduler
  # must see the tenant's covering suppressions itself. The cascade of a
  # suppression stops the enrollment, so the tests below suppress an address
  # no contact has and only then give it to the contact (F1).

  # The accepted first touch is sent; the enrollment is at its follow-up
  # step with one `followup` job scheduled at its due time.
  defp scheduled!(ctx) do
    %{lead: lead} = approved!(ctx)
    assert %{success: 1} = deliver!()
    enrollment = enrollment!(ctx, lead)
    assert [job] = all_enqueued(queue: :followup)
    assert job.args["enrollment_id"] == enrollment.id
    %{lead: lead, enrollment: enrollment, job: job}
  end

  # F1 (plan §5): the suppression is created while no contact matches it,
  # so its cascade touches nothing; then the contact's email is changed as
  # ADM. The scheduler's own read is then the only defence against a
  # `draft_followup` of a covered address.
  defp f1!(ctx, scope) do
    %{lead: lead} = scheduled = scheduled!(ctx)
    contact = contact!(ctx, lead)
    [local, _domain] = contact.email |> to_string() |> String.split("@")
    domain = "followup-red.test"
    email = "#{local}@#{domain}"
    value = if scope == :email, do: email, else: domain

    {:ok, suppression} = Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
    assert reload!(ctx, lead).status == :in_outreach
    assert enrollment!(ctx, lead).status == :active

    {:ok, changed} = Sales.update(contact, :change_email, %{email: email}, actor: ctx.admin)
    assert to_string(changed.email) == email

    Map.merge(scheduled, %{suppression: suppression, email: email})
  end

  # F1 step 3: before the worker runs, the enrollment is active at the job's
  # step, its campaign is active, the due time is not after the frozen clock
  # and a next step exists.
  defp assert_runnable!(ctx, lead, job) do
    enrollment = enrollment!(ctx, lead)
    {:ok, campaign} = Sales.fetch(Sales.Campaign, enrollment.campaign_id, actor: ctx.admin)

    {:ok, steps} =
      Sales.list_records(Sales.SequenceStep,
        filter: [sequence_id: campaign.sequence_id],
        actor: ctx.admin
      )

    position = job.args["step_position"]
    assert enrollment.status == :active
    assert enrollment.current_step_position == position
    assert campaign.status == :active
    assert DateTime.compare(enrollment.next_step_due_at, Clock.utc_now()) != :gt
    assert Enum.any?(steps, &(&1.position > position)), "no sequence step after #{position}"
  end

  defp inputs!(ctx, decision) do
    {:ok, json} = Audit.read_content(decision.inputs_sha256, actor: ctx.admin)
    Jason.decode!(json)
  end

  test "W1: an email suppression of the contact's current address stops the follow-up (F1)",
       ctx do
    %{enrollment: enrollment, job: job, lead: lead, suppression: suppression} = f1!(ctx, :email)
    Clock.freeze(enrollment.next_step_due_at)
    assert_runnable!(ctx, lead, job)

    assert %{success: 1} = followups!()
    assert [decision] = decisions_about!(ctx, enrollment.id, :followup_next_step)
    assert decision.outcome == "stop"
    assert inputs!(ctx, decision)["suppression_ids"] == [suppression.id]
    assert events_of_type(ctx.tenant, "sdr.followup.due") == []
  end

  test "W2: a domain suppression of the contact's current domain stops the follow-up (F1)",
       ctx do
    %{enrollment: enrollment, job: job, lead: lead, suppression: suppression} = f1!(ctx, :domain)
    Clock.freeze(enrollment.next_step_due_at)
    assert_runnable!(ctx, lead, job)

    assert %{success: 1} = followups!()
    assert [decision] = decisions_about!(ctx, enrollment.id, :followup_next_step)
    assert decision.outcome == "stop"
    assert inputs!(ctx, decision)["suppression_ids"] == [suppression.id]
    assert events_of_type(ctx.tenant, "sdr.followup.due") == []
  end

  # Control: the allow case.
  test "W3: a suppression of another address leaves the follow-up to be drafted", ctx do
    %{enrollment: enrollment, job: job, lead: lead} = scheduled!(ctx)

    {:ok, _other} =
      Outreach.suppress(%{scope: :email, value: "w3.someone-else@followup-red.test"},
        actor: ctx.admin
      )

    Clock.freeze(enrollment.next_step_due_at)
    assert_runnable!(ctx, lead, job)

    assert %{success: 1} = followups!()

    assert [%{outcome: "draft_followup"}] =
             decisions_about!(ctx, enrollment.id, :followup_next_step)

    assert [_event] = events_of_type(ctx.tenant, "sdr.followup.due")
  end

  # W4 (plan §3 item 5, test-seam builds only): an injected lookup error on
  # an active, uncovered enrollment fails the job closed. Retry and discard
  # follow the Oban error contract (`max_attempts: 3`) and are not observed.
  test "W4: an injected suppression-lookup error fails the job: {:error, :suppression_lookup_failed}, no Decision, no signal, no denial",
       ctx do
    %{enrollment: enrollment, job: job, lead: lead} = scheduled!(ctx)
    Clock.freeze(enrollment.next_step_due_at)
    assert_runnable!(ctx, lead, job)
    email = to_string(contact!(ctx, lead).email)
    assert Outreach.matching_suppressions(email, actor: ctx.admin) == {:ok, []}
    denials = length(events_of_type(ctx.tenant, "authz.denied"))
    put_env!(@lookup_fault, :error)

    assert perform_job(FollowupWorker, job.args) == {:error, :suppression_lookup_failed}
    assert decisions_about!(ctx, enrollment.id, :followup_next_step) == []
    assert events_of_type(ctx.tenant, "sdr.followup.due") == []
    assert length(events_of_type(ctx.tenant, "authz.denied")) == denials
  end
end

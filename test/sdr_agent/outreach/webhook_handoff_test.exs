defmodule SdrAgent.Outreach.WebhookHandoffTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 K (Q-O5; T-K7, T-K8, T-K9, T-K10): the
  reply hand-off deferral of section 6.7 (Decided, owner, D-174, Q-O5 = no
  wait). A matched unsubscribe-bearing reply whose `SDRAgent` definition is
  unavailable commits its reply phase at once (Reply, `unsubscribe_rule`
  Decision, `unsubscribe_reply` Suppression and every effect), leaves the
  WebhookEvent `received` and returns `{:error,
  :agent_definition_unavailable}` so the job retries; a later attempt (or an
  operator retry) of the same event resumes only the hand-off, exactly once;
  a duplicate event never resumes it; the final attempt fails the event as
  `:crash` with the fixed reason. T-K7p is a RED-3 [P] case
  (`webhook_handoff_race_test.exs`); T-K11 is a GREEN mutation check.

  Setup: the seeded demo tenant (`SdrAgent.SDRCase`, as every matched-reply
  suite: `AuditCase` cannot build a matched delivery), lead "01" drafted,
  approved and delivered, plus an approved follow-up whose delivery is still
  pending. A delivered message needs a drafting run, and a run needs the
  `SDRAgent` row (its FK), so "no definition" is produced in the test body
  by `hide_definition!/1`: one sandboxed raw UPDATE renames the tenant's
  `SDRAgent` rows, so no `(tenant, "SDRAgent", version)` row exists and
  `bootstrap_definitions/1` can register a fresh one (rolled back with the
  test; `agent_definitions` has no trigger). The retired variant uses
  `Agents.retire_definition/2`. Jobs are driven through
  `WebhookWorker.perform/1` with the event's real job and an explicit
  `attempt`/`max_attempts`; the job row is then set to the state Oban leaves
  (`completed` after an `:ok` final attempt), as `webhook_retry_test.exs`
  does, before an operator retry.

  RED form: T-K7 (both variants), the T-K9 duplicate-while-owed and re-run
  cases, and the T-K10 terminal, retry-miss and gap cases call no new
  function and fail at their first subject assertion on main, where
  `ReplyIntake` registers (`lib/sdr_agent/sdr/reply_intake.ex:28`) and hands
  off at once (behavioural). T-K8, the T-K9 resume and the T-K10 recovery
  need `SDR.bootstrap_definitions/1` and guard it first (structural). The
  first T-K9 case is a control (duplicate behaviour is unchanged from main).

  Interface names chosen here for review:
    * `SdrAgent.SDR.bootstrap_definitions(tenant_id)` → `{:ok, definition}`
      (shared RED-2 decision);
    * the Failure message is `"webhook event not processed: " <> reason`,
      main's `WebhookEvent.failed_message/1` (unchanged, plan section 8.1),
      with `reason` exactly "reply hand-off pending: agent definition
      unavailable" (section 6.7.3), also the `webhook.failed` argument;
    * "the send gate refuses the contact" is observed as the agent's
      suppression gate (`SuppressionCheck.Store.check/2` → `:suppressed`
      with the new Suppression) and the delivery send gate leaving the
      follow-up delivery cancelled with no capture (every claimable
      delivery of the contact is cancelled by the effects);
    * "the job's errors": the `{:error, reason}` values the worker returns
      (explicit-attempt cases) and, separately, the error Oban itself
      persists in `oban_jobs.errors` for one real, bounded execution of a
      retryable attempt (`Oban.drain_queue/1`, Codex 480e1baf MF5); no error
      is ever written by the test;
    * T-K7's matched lead also has two raw sandbox enrollments in other
      active campaigns (one active, one paused), so the deferred T1 is shown
      to run ApplySuppression's enrollment-stopping branch, not only
      ApplyReply's (Codex 480e1baf important 1).
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Outreach.WebhookWorker
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDR.SuppressionCheck

  @sdr SdrAgent.SDR
  @reason "reply hand-off pending: agent definition unavailable"
  @unavailable {:error, :agent_definition_unavailable}
  @worker "SdrAgent.Outreach.WebhookWorker"
  # Events the hand-off itself writes (section 6.7.4, "Audit trail").
  @handoff_types ~w(settings.snapshot.created agents.run.created sdr.reply.received
                    webhook.processed operations.failure.resolved)

  setup ctx do
    approved = approved!(ctx)
    %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)
    followup = followup_draft!(ctx, approved)
    followup_approval = approve!(ctx, followup, operator!(ctx, :reviewer))

    %{
      matched: %{
        delivery: delivery,
        lead: approved.lead,
        enrollment: enrollment!(ctx, approved.lead),
        followup: followup,
        followup_approval: followup_approval,
        pending: delivery_of!(ctx, followup_approval)
      }
    }
  end

  describe "T-K7 the reply phase commits; only the hand-off waits" do
    # Behavioural RED: main registers the definition in the reply
    # transaction and hands off at once (the job returns :ok).
    test "T-K7 definition missing, attempt 1 of 3: deferred, reply phase committed, no hand-off",
         ctx do
      hide_definition!(ctx)
      # ApplySuppression's enrollment branch (active/paused → stopped) in the
      # deferred T1 itself: the matched enrollment becomes replied through
      # ApplyReply, so two more enrollments of the same lead, in other
      # campaigns, one active and one paused, are the suppression's targets.
      extra = extra_enrollments!(ctx)
      reply = unsubscribe_reply!(ctx)

      assert perform!(reply.event, 1) == @unavailable,
             "C3-02: a missing definition must defer the hand-off, not complete the job"

      assert_reply_phase!(ctx, reply)

      for enrollment <- extra do
        assert {:ok, stopped} =
                 Sales.fetch(Sales.CampaignEnrollment, enrollment.id, actor: ctx.admin)

        assert {stopped.status, stopped.stop_reason} == {:stopped, :unsubscribe},
               "C3-02: the deferred T1 stops the covered contact's active and paused enrollments"
      end

      refute_handoff!(ctx, reply.event)
      assert webhook!(ctx, reply.event).processing_status == :received

      assert sdr_definitions(ctx) == [],
             "C3-02: the reply path registers no definition (section 7.2)"
    end

    # Behavioural RED: main reuses the retired row and hands off.
    test "T-K7 retired-definition variant: deferred the same way; the retired row stays the only one",
         ctx do
      [definition] = sdr_definitions(ctx)

      assert {:ok, %{status: :retired}} =
               Agents.retire_definition(definition, Kernel.opts(ctx.tenant.id))

      reply = unsubscribe_reply!(ctx)

      assert perform!(reply.event, 1) == @unavailable,
             "C3-02: a retired definition must defer the hand-off"

      assert_reply_phase!(ctx, reply)
      refute_handoff!(ctx, reply.event)
      assert webhook!(ctx, reply.event).processing_status == :received
      assert [%{id: id, status: :retired}] = sdr_definitions(ctx)
      assert id == definition.id
    end
  end

  describe "T-K8 the hand-off is retried and completes once the definition exists" do
    # Structural RED: SDR.bootstrap_definitions/1 is absent.
    test "T-K8 bootstrap, then attempt 2 hands off exactly once; nothing of the reply phase again",
         ctx do
      present!(@sdr, :bootstrap_definitions, 1)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)

      assert {:ok, _definition} = bootstrap(ctx)
      before = event_counts(ctx)

      assert perform!(reply.event, 2) == :ok
      assert webhook!(ctx, reply.event).processing_status == :processed
      assert_handed_off_once!(ctx, reply)
      assert_only_handoff_events!(before, event_counts(ctx))
      assert reply_phase(ctx) == phase

      settled = event_counts(ctx)
      assert perform!(reply.event, 3) == :ok
      assert event_counts(ctx) == settled
      assert [_run] = reply_runs(ctx, reply.event)
    end

    # Structural RED: SDR.bootstrap_definitions/1 is absent.
    test "T-K8 variant: attempt 2 misses again with nothing written; attempt 3 after bootstrap completes",
         ctx do
      present!(@sdr, :bootstrap_definitions, 1)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)
      counts = event_counts(ctx)

      assert perform!(reply.event, 2) == @unavailable
      assert event_counts(ctx) == counts
      assert reply_phase(ctx) == phase
      refute_handoff!(ctx, reply.event)

      assert {:ok, _definition} = bootstrap(ctx)
      before = event_counts(ctx)

      assert perform!(reply.event, 3) == :ok
      assert webhook!(ctx, reply.event).processing_status == :processed
      assert_handed_off_once!(ctx, reply)
      assert_only_handoff_events!(before, event_counts(ctx))
      assert reply_phase(ctx) == phase
    end
  end

  # C3-02 G6 (plan r8 sections 16.4, 16.13 R-W4; Codex G6-R1): the deferred
  # hand-off of an event whose Message-ID is padded resumes its own Reply,
  # which `Reply.message_id`'s constraints stored trimmed: the resume's lookup
  # and key use the same represented value.
  describe "T-K8b a padded Message-ID resumes its own Reply" do
    # Behavioural RED: on main attempt 2 looks the Reply up with the untrimmed
    # Message-ID, misses its own Reply and fails on a unique identity (or, if
    # that lookup matched, this case passes as a control; the RED evidence
    # states which).
    test "T-K8b attempt 2 of a padded deferred reply finds its own Reply and hands off exactly once",
         ctx do
      present!(@sdr, :bootstrap_definitions, 1)
      hide_definition!(ctx)
      represented = "<c302pad#{SalesFixtures.unique()}@prospect.example.test>"
      reply = unsubscribe_reply!(ctx, message_id: " " <> represented <> " ")
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)

      stored = replies!(ctx)
      assert match?([_], stored), "C3-02: attempt 1 stores exactly one Reply"
      [own] = stored
      assert to_string(own.message_id) == represented

      assert {:ok, _definition} = bootstrap(ctx)
      before = event_counts(ctx)

      assert perform!(reply.event, 2) == :ok
      assert webhook!(ctx, reply.event).processing_status == :processed
      assert_handed_off_once!(ctx, reply)
      assert_only_handoff_events!(before, event_counts(ctx))
      assert reply_phase(ctx) == phase
    end
  end

  describe "T-K9 duplicate events do not double-apply" do
    # Control: passes on main and must stay green (plan section 10.1,
    # duplicate behaviour unchanged).
    test "T-K9 (control) a duplicate after a completed hand-off is processed and writes nothing",
         ctx do
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == :ok
      phase = reply_phase(ctx)
      runs = length(reply_runs(ctx, reply.event))

      duplicate = duplicate!(ctx, reply)
      assert perform!(duplicate.event, 1) == :ok

      assert webhook!(ctx, duplicate.event).processing_status == :processed
      assert reply_phase(ctx) == phase
      assert reply_runs(ctx, duplicate.event) == []
      assert length(reply_runs(ctx, reply.event)) == runs
    end

    # Behavioural RED: on main E hands off at attempt 1.
    test "T-K9 a duplicate while E's hand-off is owed: processed, writes nothing, does not resume E",
         ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)

      duplicate = duplicate!(ctx, reply)
      assert perform!(duplicate.event, 1) == :ok

      assert webhook!(ctx, duplicate.event).processing_status == :processed
      assert reply_phase(ctx) == phase
      assert reply_runs(ctx, duplicate.event) == []
      refute_handoff!(ctx, reply.event)
      assert webhook!(ctx, reply.event).processing_status == :received
    end

    # Structural RED: SDR.bootstrap_definitions/1 is absent.
    test "T-K9 E's resume after a duplicate hands off exactly once; a later duplicate is the same no-op",
         ctx do
      present!(@sdr, :bootstrap_definitions, 1)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)
      early = duplicate!(ctx, reply)
      assert perform!(early.event, 1) == :ok

      assert {:ok, _definition} = bootstrap(ctx)
      assert perform!(reply.event, 2) == :ok
      assert_handed_off_once!(ctx, reply)

      late = duplicate!(ctx, reply)
      settled = event_counts(ctx)
      assert perform!(late.event, 1) == :ok

      assert webhook!(ctx, late.event).processing_status == :processed
      assert reply_phase(ctx) == phase
      assert reply_runs(ctx, early.event) == [] and reply_runs(ctx, late.event) == []
      assert [_run] = reply_runs(ctx, reply.event)

      assert Map.drop(event_counts(ctx), ["webhook.processed"]) ==
               Map.drop(settled, ["webhook.processed"])
    end

    # Behavioural RED: on main E hands off at attempt 1.
    test "T-K9 re-running E on its own stored Reply never reaches reply/5", ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert perform!(reply.event, 1) == @unavailable
      phase = reply_phase(ctx)
      counts = event_counts(ctx)

      # Exactly the deferral: no second Reply :receive, no unique violation.
      assert perform!(reply.event, 2) == @unavailable

      assert reply_phase(ctx) == phase
      assert event_counts(ctx) == counts
      assert [_one] = suppression_events(ctx)
    end
  end

  describe "T-K10 the final-attempt terminal state" do
    # Behavioural RED: on main attempt 1 already completes the hand-off.
    test "T-K10 attempt 3 of 3 still missing: failed :crash with the fixed reason, Failure open, no run; no value leaks",
         ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)

      {results, log} = with_log(fn -> final_attempt!(reply.event) end)

      assert results == [@unavailable, @unavailable, :ok],
             "C3-02: attempts 1-2 defer, the final attempt records the failure"

      event = webhook!(ctx, reply.event)
      assert event.processing_status == :failed
      failure = failure!(ctx, event)
      assert {failure.class, failure.severity, failure.status} == {:crash, :warning, :open}
      assert failure.message == "webhook event not processed: " <> @reason

      assert [failed] =
               for(
                 e <- events_of_type(ctx.tenant, "webhook.failed"),
                 e.subject_id == event.id,
                 do: e
               )

      assert failed.payload["arguments"]["reason"] == @reason
      assert {:ok, listed} = Operations.list_failed_webhooks(actor: ctx.admin)
      assert event.id in Enum.map(listed, & &1.id)

      assert_reply_phase!(ctx, reply)
      refute_handoff!(ctx, reply.event)

      # perform/1 is called directly here, so no executor persisted these
      # attempts' errors; the persisted oban_jobs.errors are checked by the
      # real-execution case below.
      exposed = [
        @reason,
        Jason.encode!(failed.payload),
        inspect(failure),
        inspect(results),
        log
      ]

      for text <- exposed, value <- reply.canaries do
        refute String.contains?(text, value), "C3-02: a reply value reached a failure surface"
      end
    end

    # Behavioural RED: on main the executed attempt hands off and returns :ok,
    # so Oban persists no error. Bounded: one synchronous drain of the
    # event's own queue, without recursion or scheduled jobs.
    test "T-K10 a real Oban execution of a retryable missing-definition attempt persists a value-free error for that job",
         ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      job = job_of(reply.event)
      assert {job.state, job.attempt, job.errors} == {"available", 0, []}

      {drained, log} =
        with_log(fn ->
          Oban.drain_queue(queue: :integration, with_safety: true, with_recursion: false)
        end)

      assert drained.failure >= 1, "C3-02: the deferred attempt must fail the job for a retry"
      executed = Repo.reload!(job)

      assert {executed.state, executed.attempt} == {"retryable", 1},
             "C3-02: a deferred, non-final attempt leaves the job retryable"

      assert [%{"attempt" => 1, "error" => error} | _] = executed.errors,
             "C3-02: Oban persisted an error entry for this job's attempt"

      assert is_binary(error) and error != ""
      assert webhook!(ctx, reply.event).processing_status == :received
      assert_reply_phase!(ctx, reply)

      # C3-02 G8 (MH-3c): one assertion and one message per sink, so a failure
      # names the sink that leaked: this job's persisted errors first, then
      # the captured log.
      errors_text = Jason.encode!(executed.errors)

      refute Enum.any?(reply.canaries, &String.contains?(errors_text, &1)),
             "C3-02: a reply value reached oban_jobs.errors"

      refute Enum.any?(reply.canaries, &String.contains?(log, &1)),
             "C3-02: a reply value reached the captured log"
    end

    # Structural RED: SDR.bootstrap_definitions/1 is absent.
    test "T-K10 bootstrap and Outreach.retry_webhook/2: hands off exactly once, processed, Failure resolved",
         ctx do
      present!(@sdr, :bootstrap_definitions, 1)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert final_attempt!(reply.event) == [@unavailable, @unavailable, :ok]
      phase = reply_phase(ctx)
      event = webhook!(ctx, reply.event)
      assert event.processing_status == :failed
      completed!(reply.event)

      assert {:ok, _definition} = bootstrap(ctx)

      assert {:ok, %{event_id: id, ordinal: 1}} =
               Outreach.retry_webhook(event.id, actor: ctx.admin)

      assert id == event.id
      assert %{success: 1} = process!()

      assert webhook!(ctx, reply.event).processing_status == :processed
      assert failure!(ctx, event).status == :resolved
      assert_handed_off_once!(ctx, reply)
      assert reply_phase(ctx) == phase
    end

    # Behavioural RED: on main attempt 1 already completes the hand-off.
    test "T-K10 an operator retry that also misses: webhook.retry_failed consumes it, Failure stays open",
         ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert final_attempt!(reply.event) == [@unavailable, @unavailable, :ok]
      event = webhook!(ctx, reply.event)
      completed!(reply.event)

      assert {:ok, %{ordinal: 1}} = Outreach.retry_webhook(event.id, actor: ctx.admin)
      assert %{success: 1} = process!()

      assert webhook!(ctx, reply.event).processing_status == :failed
      assert [consumed] = retry_failures(ctx, event)
      assert consumed.payload["arguments"]["ordinal"] == 1
      assert consumed.payload["arguments"]["reason"] == @reason
      assert failure!(ctx, event).status == :open
      refute_handoff!(ctx, reply.event)
    end

    # Behavioural RED: on main attempt 1 already completes the hand-off.
    test "T-K10 the documented gap: retry_limit_reached, then retry_window_expired; the hand-off stays owed",
         ctx do
      hide_definition!(ctx)
      reply = unsubscribe_reply!(ctx)
      assert final_attempt!(reply.event) == [@unavailable, @unavailable, :ok]
      event = webhook!(ctx, reply.event)
      completed!(reply.event)

      for ordinal <- 1..3 do
        assert {:ok, %{ordinal: ^ordinal}} = Outreach.retry_webhook(event.id, actor: ctx.admin)
        assert %{success: 1} = process!()
      end

      assert length(retry_failures(ctx, event)) == 3
      assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :retry_limit_reached}
      assert_still_owed!(ctx, reply, event)

      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job_of(reply.event).id))

      assert Outreach.retry_webhook(event.id, actor: ctx.admin) ==
               {:error, :retry_window_expired}

      assert_still_owed!(ctx, reply, event)
    end
  end

  ## The definition

  # Test-only: no `(tenant, "SDRAgent", version)` row remains (renamed in
  # the sandbox; the drafting run keeps its FK by id).
  defp hide_definition!(ctx) do
    %{num_rows: hidden} =
      Repo.query!(
        "UPDATE agent_definitions SET name = $1 WHERE tenant_id = $2 AND name = 'SDRAgent'",
        ["SDRAgent-c302-hidden", Ecto.UUID.dump!(ctx.tenant.id)]
      )

    assert hidden >= 1, "C3-02: not established: the drafting run had no SDRAgent row"
    assert sdr_definitions(ctx) == []
  end

  defp sdr_definitions(ctx) do
    AgentDefinition
    |> Ash.Query.filter(tenant_id == ^ctx.tenant.id and name == "SDRAgent")
    |> Ash.read!(Kernel.opts(ctx.tenant.id))
  end

  defp bootstrap(ctx), do: call(@sdr, :bootstrap_definitions, [ctx.tenant.id])

  ## Events and jobs

  # An unsubscribe-bearing reply (rule phrases "remove me", "unsubscribe")
  # to the delivered message, with canary Message-ID and body values.
  defp unsubscribe_reply!(ctx, opts \\ []) do
    canary = "c302canary#{SalesFixtures.unique()}"
    message_id = Keyword.get(opts, :message_id, "<#{canary}@prospect.example.test>")
    text = Keyword.get(opts, :text, "Please remove me from your list. Unsubscribe. #{canary}body")
    delivery = ctx.matched.delivery

    body =
      delivery
      |> reply_body(text, id: "evt_c302_" <> Ecto.UUID.generate())
      |> Jason.decode!()
      |> put_in(["data", "message_id"], message_id)
      |> Jason.encode!()

    assert {:ok, %{status: :accepted, event: event}} = ingest!("reply", body)

    %{
      event: event,
      message_id: message_id,
      text: text,
      email: String.downcase(to_string(delivery.recipient_email)),
      canaries: [message_id, canary, String.downcase(to_string(delivery.recipient_email))]
    }
  end

  # Another WebhookEvent (new external id) carrying E's Message-ID and body.
  defp duplicate!(ctx, reply),
    do: unsubscribe_reply!(ctx, message_id: reply.message_id, text: reply.text)

  # Two more enrollments of the matched lead in other active campaigns, one
  # active and one paused (raw sandbox copies of the matched enrollment row:
  # :enroll needs a qualified lead, and the lead is in outreach by now).
  defp extra_enrollments!(ctx) do
    base = ctx.matched.enrollment

    for {status, atom} <- [{"active", :active}, {"paused", :paused}] do
      campaign = SalesFixtures.active_campaign!(ctx.tenant)
      id = Ecto.UUID.generate()

      tamper!(
        "INSERT INTO campaign_enrollments SELECT (jsonb_populate_record(" <>
          "NULL::campaign_enrollments, to_jsonb(t) || $2::jsonb)).* " <>
          "FROM campaign_enrollments AS t WHERE t.id = $1",
        [
          Ecto.UUID.dump!(base.id),
          %{"id" => id, "campaign_id" => campaign.id, "status" => status}
        ]
      )

      assert {:ok, enrollment} = Sales.fetch(Sales.CampaignEnrollment, id, actor: ctx.admin)
      assert {enrollment.status, enrollment.campaign_id} == {atom, campaign.id}
      enrollment
    end
  end

  defp job_of(event) do
    Repo.one!(
      from(j in Oban.Job,
        where: j.worker == @worker and fragment("?->>'webhook_event_id' = ?", j.args, ^event.id)
      )
    )
  end

  # The event's real job, run with an explicit attempt (final? is
  # attempt >= max_attempts).
  defp perform!(event, attempt, max_attempts \\ 3),
    do: WebhookWorker.perform(%{job_of(event) | attempt: attempt, max_attempts: max_attempts})

  defp final_attempt!(event), do: for(attempt <- 1..3, do: perform!(event, attempt))

  # The row state Oban leaves when the final attempt returned :ok.
  defp completed!(event) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job_of(event).id),
        set: [state: "completed", attempt: 3, completed_at: DateTime.utc_now()]
      )
  end

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  defp failure!(ctx, event) do
    {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
    failure
  end

  defp retry_failures(ctx, event),
    do:
      for(
        e <- events_of_type(ctx.tenant, "webhook.retry_failed"),
        e.subject_id == event.id,
        do: e
      )

  defp event_counts(ctx), do: Enum.frequencies_by(events(ctx.tenant), & &1.event_type)

  ## The reply phase

  defp reply_phase(ctx) do
    replies = replies!(ctx)

    %{
      replies: Enum.map(replies, &{&1.id, &1.match_status}),
      decisions:
        Enum.flat_map(replies, fn r ->
          Enum.map(decisions_about!(ctx, r.id, :unsubscribe_rule), & &1.id)
        end),
      suppressions: Enum.map(unsubscribe_suppressions(ctx), & &1.id),
      created: length(events_of_type(ctx.tenant, "outreach.suppression.created")),
      received: length(events_of_type(ctx.tenant, "outreach.reply.received"))
    }
  end

  defp unsubscribe_suppressions(ctx),
    do: Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))

  defp suppression_events(ctx) do
    [suppression] = unsubscribe_suppressions(ctx)

    for e <- events_of_type(ctx.tenant, "outreach.suppression.created"),
        e.subject_id == suppression.id,
        do: e
  end

  defp assert_reply_phase!(ctx, reply) do
    m = ctx.matched
    assert [stored] = replies!(ctx)

    assert {stored.match_status, stored.webhook_event_id, stored.delivery_operation_id} ==
             {:matched, reply.event.id, m.delivery.id}

    assert [rule] = decisions_about!(ctx, stored.id, :unsubscribe_rule)
    assert {rule.mode, rule.outcome} == {:deterministic, "unsubscribe"}
    assert [suppression] = unsubscribe_suppressions(ctx)

    assert {suppression.scope, to_string(suppression.value)} == {:email, reply.email}

    assert {suppression.decision_id, suppression.reply_id, suppression.webhook_event_id} ==
             {rule.id, stored.id, reply.event.id}

    assert [_one] = suppression_events(ctx)
    assert_effects!(ctx, m)
    assert_gates_refuse!(ctx, m, reply, suppression)
  end

  # ApplyReply (enrollment replied; the unsent follow-up delivery, its
  # queued draft and granted approval cancelled/invalidated) and
  # ApplySuppression (the open lead stopped).
  defp assert_effects!(ctx, m) do
    assert %{status: :stopped, status_reason: "suppressed: unsubscribe_reply"} =
             reload!(ctx, m.lead)

    assert reload!(ctx, m.enrollment).status == :replied
    assert outreach!(ctx, m.pending).state == :cancelled
    assert draft!(ctx, m.followup).status == :cancelled
    approval = outreach!(ctx, m.followup_approval)
    assert {approval.status, approval.invalidated_reason} == {:invalidated, :campaign_closed}
  end

  defp assert_gates_refuse!(ctx, m, reply, suppression) do
    assert {:ok, matching} = Outreach.matching_suppressions(reply.email, actor: ctx.admin)
    assert suppression.id in Enum.map(matching, & &1.id)

    context = %{tenant_id: ctx.tenant.id, contact_id: m.delivery.recipient_contact_id}

    assert {:ok, :suppressed, %{"suppression_ids" => ids}} =
             SuppressionCheck.Store.check(reply.email, context)

    assert suppression.id in ids

    assert Delivery.attempt(m.pending.id, ctx.tenant.id) == :ok
    assert outreach!(ctx, m.pending).state == :cancelled
    assert Enum.filter(receipts!(ctx, m.pending), &(&1.kind == :captured)) == []
  end

  ## The hand-off

  defp reply_runs(ctx, event) do
    AgentRun
    |> Ash.Query.filter(tenant_id == ^ctx.tenant.id and correlation_id == ^event.id)
    |> Ash.read!(Kernel.opts(ctx.tenant.id))
  end

  defp reply_signals(ctx, reply_id) do
    for e <- events_of_type(ctx.tenant, "sdr.reply.received"),
        e.payload["data"]["reply_id"] == reply_id,
        do: e
  end

  defp processed_events(ctx, event) do
    for e <- events_of_type(ctx.tenant, "webhook.processed"), e.subject_id == event.id, do: e
  end

  defp refute_handoff!(ctx, event) do
    assert reply_runs(ctx, event) == [], "C3-02: no reply AgentRun while the hand-off is owed"
    assert all_enqueued(worker: ReplyWorker) == []
    assert events_of_type(ctx.tenant, "sdr.reply.received") == []
    assert processed_events(ctx, event) == []
  end

  defp assert_handed_off_once!(ctx, reply) do
    assert [stored] = replies!(ctx)
    assert [run] = reply_runs(ctx, reply.event)

    assert {run.correlation_id, run.trigger_signal_type, run.usage_origin} ==
             {reply.event.id, "sdr.reply.received", :reply}

    assert {run.lead_id, run.campaign_id} ==
             {stored.lead_id, ctx.matched.delivery.campaign_id}

    assert [_job] = all_enqueued(worker: ReplyWorker)
    assert [_signal] = reply_signals(ctx, stored.id)
    assert [_processed] = processed_events(ctx, reply.event)
  end

  # Only the hand-off's own events were appended, each at most once.
  defp assert_only_handoff_events!(before, now) do
    assert Map.drop(now, @handoff_types) == Map.drop(before, @handoff_types),
           "C3-02: the resume wrote a reply-phase event again"

    for type <- ["agents.run.created", "sdr.reply.received", "webhook.processed"] do
      assert Map.get(now, type, 0) == Map.get(before, type, 0) + 1, type
    end
  end

  defp assert_still_owed!(ctx, reply, event) do
    assert webhook!(ctx, reply.event).processing_status == :failed
    assert failure!(ctx, event).status == :open
    assert [%{match_status: :matched}] = replies!(ctx)
    assert reply_runs(ctx, reply.event) == []
  end

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end
end

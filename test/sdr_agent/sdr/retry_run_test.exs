defmodule SdrAgent.SDR.RetryRunTest do
  @moduledoc """
  S13b operator retry of agent runs (soft-stop v3 PASS, Codex 9a400910):
  `SDR.retry_run/2` is the only path. Active ADM only; one child per prior
  run; at most 3 retries after the original; the original work must have
  stopped; the trigger is re-read from its durable signal; lead and
  campaign gates hold; the new job, Operation and run commit together and
  actually execute. Refusals write nothing.
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]
  import SdrAgent.OutreachFixtures, only: [approved!: 2, deliver!: 0, outreach!: 2, put_env!: 2]
  import SdrAgent.WebhookFixtures, only: [ingest!: 2, process!: 0, reply_body: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FakeBrain

  defmodule InvalidQualification do
    @moduledoc "Test responder: an invalid qualification score fails the run."
    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  # An assignment run of lead 01 that failed on invalid model output.
  defp failed_run!(ctx) do
    %{run: run} =
      assign!(ctx, "01", model: [provider_options: [responder: InvalidQualification]])

    assert %{success: 1} = drain!()
    failed = run!(ctx, run)
    assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}
    failed
  end

  defmodule InvalidClassification do
    @moduledoc "Test responder: an out-of-range confidence fails the reply run."
    def respond("sdr.reply_classification" = op, input),
      do: %{FakeBrain.respond(op, input) | confidence: 7}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  # A reply run of lead 01 that failed on an invalid classification.
  defp failed_reply_run!(ctx) do
    approved = approved!(ctx, "01")
    assert %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)
    put_env!(:fake_model_responder, InvalidClassification)

    assert {:ok, %{status: :accepted}} =
             ingest!("reply", reply_body(delivery, "Sounds interesting, let's talk."))

    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)
    put_env!(:fake_model_responder, FakeBrain)

    {:ok, runs} = Agents.list_runs(actor: ctx.admin)
    assert [failed] = Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received"))
    assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}
    failed
  end

  defp assessments!(ctx) do
    {:ok, assessments} =
      SdrAgent.Outreach.list_records(SdrAgent.Outreach.ReplyAssessment, actor: ctx.admin)

    assessments
  end

  defp ledger_size(ctx), do: length(events(ctx.tenant))

  describe "an assignment run" do
    test "is retried as a new run with its own Operation and job, and the work executes",
         ctx do
      prior = failed_run!(ctx)

      assert {:ok, %{run: run, operation: operation, job: job}} =
               SDR.retry_run(prior.id, actor: ctx.admin)

      assert {run.status, run.retry_of_id, run.operation_id} ==
               {:queued, prior.id, operation.id}

      assert {run.trigger_signal_id, run.lead_id} == {prior.trigger_signal_id, prior.lead_id}

      assert {operation.status, operation.kind, operation.oban_job_id} ==
               {:enqueued, :research_lead, job.id}

      assert job.worker == "SdrAgent.SDR.AgentWorker"
      assert job.args["signal"]["id"] == prior.trigger_signal_id

      {:ok, failure} = Operations.get_failure(prior.attention_failure_id, actor: ctx.admin)
      assert failure.status == :resolved
      assert {failure.resolved_by_type, failure.resolved_by_id} == {:user, ctx.admin.id}
      assert failure.resolution_note =~ run.id

      assert %{success: 1} = drain!()
      done = run!(ctx, run)
      assert done.status == :succeeded, inspect({done.status_reason, done.failure_reason})
      assert [_] = events_of_type(ctx.tenant, "agents.run.retried")
    end

    test "a second retry of the same run is :already_retried and writes nothing", ctx do
      prior = failed_run!(ctx)
      {:ok, _} = SDR.retry_run(prior.id, actor: ctx.admin)
      before = ledger_size(ctx)

      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :already_retried}
      assert ledger_size(ctx) == before
    end

    test "retries are bounded: three after the original, then :retry_limit_reached", ctx do
      put_env!(:fake_model_responder, InvalidQualification)
      prior = failed_run!(ctx)

      last =
        Enum.reduce(1..3, prior, fn _, parent ->
          {:ok, %{run: run}} = SDR.retry_run(parent.id, actor: ctx.admin)
          assert %{success: 1} = drain!()
          assert run!(ctx, run).status == :failed
          run
        end)

      before = ledger_size(ctx)
      assert SDR.retry_run(last.id, actor: ctx.admin) == {:error, :retry_limit_reached}
      assert ledger_size(ctx) == before
    end

    test "while the original job is still live: :prior_work_live", ctx do
      %{run: run} = assign!(ctx, "01")
      {:ok, cancelled} = Agents.cancel_run(run, actor: ctx.admin)
      before = ledger_size(ctx)

      assert SDR.retry_run(cancelled.id, actor: ctx.admin) == {:error, :prior_work_live}
      assert ledger_size(ctx) == before
    end

    test "with another queued or running run on the lead: :assignment_active", ctx do
      prior = failed_run!(ctx)

      {:ok, _queued} =
        Agents.create_run(
          %{
            agent_definition_id: prior.agent_definition_id,
            lead_id: prior.lead_id,
            campaign_id: prior.campaign_id,
            trigger_signal_type: "sdr.lead.assigned",
            trigger_signal_id: Ecto.UUID.generate(),
            correlation_id: Ecto.UUID.generate(),
            phase: :discover,
            max_model_calls: 5,
            max_tool_calls: 10
          },
          actor: ctx.agent
        )

      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :assignment_active}
    end

    test "a stopped lead or a paused campaign is not retried", ctx do
      prior = failed_run!(ctx)

      {:ok, campaign} =
        SdrAgent.Sales.fetch(SdrAgent.Sales.Campaign, ctx.campaign_id, actor: ctx.admin)

      {:ok, _} = SDR.pause_campaign(campaign, actor: ctx.admin)

      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :campaign_not_active}

      contact = SdrAgent.OutreachFixtures.contact!(ctx, fixture_lead!(ctx, "01"))

      {:ok, _} =
        SdrAgent.Outreach.suppress(
          %{scope: :email, value: to_string(contact.email)},
          actor: ctx.admin
        )

      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :lead_not_retryable}
    end

    test "a pruned original job cannot prove the old work stopped: :original_job_missing",
         ctx do
      prior = failed_run!(ctx)
      {:ok, op} = Operations.get_operation(prior.operation_id, actor: ctx.admin)
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^op.oban_job_id))

      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :original_job_missing}
    end
  end

  describe "a reply run" do
    test "is retried with a new ReplyWorker job; the classification is then recorded", ctx do
      prior = failed_reply_run!(ctx)
      assert assessments!(ctx) == []

      assert {:ok, %{run: run, operation: nil, job: job}} =
               SDR.retry_run(prior.id, actor: ctx.admin)

      assert {run.retry_of_id, run.operation_id, run.trigger_signal_id} ==
               {prior.id, nil, prior.trigger_signal_id}

      assert {job.worker, job.queue, job.args["run_id"]} ==
               {"SdrAgent.SDR.ReplyWorker", "agent", run.id}

      assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)
      assert run!(ctx, run).status == :succeeded
      assert [%{agent_run_id: agent_run_id}] = assessments!(ctx)
      assert agent_run_id == run.id

      # The child succeeded: it is not retryable, and the prior has its child.
      assert SDR.retry_run(run.id, actor: ctx.admin) == {:error, :not_retryable}
      assert SDR.retry_run(prior.id, actor: ctx.admin) == {:error, :already_retried}
    end
  end

  describe "authorization" do
    for role <- [:reviewer, :auditor] do
      test "#{role}: Forbidden, one authz.denied, nothing queued", ctx do
        prior = failed_run!(ctx)
        actor = human(unquote(role), ctx.tenant)
        jobs = Repo.aggregate(Oban.Job, :count)

        assert {:error, %Ash.Error.Forbidden{}} = SDR.retry_run(prior.id, actor: actor)
        assert Repo.aggregate(Oban.Job, :count) == jobs

        assert [denial] =
                 Enum.filter(
                   events_of_type(ctx.tenant, "authz.denied"),
                   &(&1.actor_id == actor.id)
                 )

        assert denial.payload["action"] == "sdr_retry_run"
      end
    end

    test "a system actor is refused and audited", ctx do
      prior = failed_run!(ctx)
      assert {:error, %Ash.Error.Forbidden{}} = SDR.retry_run(prior.id, actor: ctx.agent)

      assert Enum.any?(
               events_of_type(ctx.tenant, "authz.denied"),
               &(&1.actor_type == :agent_runtime)
             )
    end

    test "the AgentRun :retry action cannot be used directly, even by an admin", ctx do
      prior = failed_run!(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.AgentRun
               |> Ash.Changeset.for_create(:retry, %{run_id: prior.id}, actor: ctx.admin)
               |> Ash.create()

      refute function_exported?(Agents, :retry_run, 2)
    end
  end
end

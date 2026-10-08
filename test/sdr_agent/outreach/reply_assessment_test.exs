defmodule SdrAgent.Outreach.ReplyAssessmentTest do
  @moduledoc """
  S9b reply classification (spec §16, S2 ReplyAssessment): a matched reply's
  processing queues an AgentRun of SDRAgent v3 whose `sdr.reply.received`
  route makes one Zoi-validated model call and records an LLM
  `reply_classification` Decision and the agent ReplyAssessment. No
  response is drafted (owner decision: classify + hand off); the hand-off
  queue lists replied leads interested first. The model may only *add* the
  unsubscribe suppression (the deterministic rule decides it first).
  """
  use SdrAgent.SDRCase, async: false

  require Ash.Query

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDR.SDRAgent

  defmodule UnsubscribeResponder do
    @moduledoc false
    def respond("sdr.reply_classification", _input) do
      %{
        classification: "unsubscribe",
        sentiment: "negative",
        intent: "wants no further contact",
        suggested_next_action: "stop",
        confidence: 0.8,
        reason: "asks not to be contacted"
      }
    end

    def respond(operation, input), do: SdrAgent.SDR.FakeBrain.respond(operation, input)
  end

  defp delivered!(ctx, key \\ "01") do
    approved = approved!(ctx, key)
    assert %{success: 1} = deliver!()
    Map.put(approved, :delivery, outreach!(ctx, approved.delivery))
  end

  defp reply!(delivery, text) do
    assert {:ok, %{status: :accepted}} = ingest!("reply", reply_body(delivery, text))
    assert %{success: 1} = process!()
  end

  defp classify!, do: Oban.drain_queue(queue: :agent, with_safety: false)

  defp assessments!(ctx) do
    {:ok, assessments} = Outreach.list_records(Outreach.ReplyAssessment, actor: ctx.admin)
    assessments
  end

  test "SDRAgent v3 routes sdr.reply.received to the classifier", _ctx do
    assert "sdr.reply.received" in SDRAgent.routed_signal_types()
    assert SdrAgent.SDR.Actions.ClassifyReply in SDRAgent.route_targets()
    # Schema version 2 refs are a new immutable definition body (#35).
    assert SDRAgent.version() == 3
  end

  test "an interested reply is classified by the agent and handed off", ctx do
    %{delivery: op, lead: lead} = delivered!(ctx)
    reply!(op, "Thanks, this sounds interesting. Could we set up a call next week?")

    assert_enqueued(worker: ReplyWorker, queue: :agent)
    assert %{success: 1} = classify!()

    [reply] = replies!(ctx)
    assert [assessment] = assessments!(ctx)

    assert {assessment.reply_id, assessment.source, assessment.classification} ==
             {reply.id, :agent, :interested}

    assert {assessment.sentiment, assessment.suggested_next_action} == {:positive, :hand_off}
    assert assessment.confidence > 0 and assessment.confidence <= 1

    {:ok, run} = Agents.get_run(assessment.agent_run_id, actor: ctx.agent)

    assert {run.status, run.trigger_signal_type, run.lead_id} ==
             {:succeeded, "sdr.reply.received", lead.id}

    {:ok, definition} = Ash.get(Agents.AgentDefinition, run.agent_definition_id, actor: ctx.admin)
    # A new reply-intake run pins the current definition (v3).
    assert {definition.name, definition.version} == {"SDRAgent", 3}

    [decision] = decisions_about!(ctx, reply.id, :reply_classification)

    assert {decision.mode, decision.outcome, decision.id} ==
             {:llm, "interested", assessment.decision_id}

    assert decision.model_invocation_id == assessment.model_invocation_id
    [invocation] = invocations!(ctx, run)
    assert {invocation.purpose, invocation.validation_status} == {:reply_classification, :valid}

    # No response is drafted for any classification (owner decision).
    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    assert Enum.all?(drafts, &(&1.status != :pending_review))

    assert {:ok, [%{lead: %{id: lead_id}, reply: %{id: reply_id}, assessment: %{id: id}}]} =
             Outreach.list_handoff_queue(actor: ctx.admin)

    assert {lead_id, reply_id, id} == {lead.id, reply.id, assessment.id}
  end

  test "the hand-off queue lists interested replies first, then the oldest hand-off", ctx do
    %{delivery: first, lead: early} = delivered!(ctx, "01")
    %{delivery: second, lead: late} = delivered!(ctx, "02")

    reply!(first, "Not right now, maybe next quarter.")
    Clock.freeze(DateTime.add(Clock.utc_now(), 60, :second))
    reply!(second, "Sounds interesting, let's talk.")
    assert %{success: 2} = classify!()

    {:ok, queue} = Outreach.list_handoff_queue(actor: ctx.admin)
    assert Enum.map(queue, & &1.lead.id) == [late.id, early.id]
    assert Enum.map(queue, & &1.assessment.classification) == [:interested, :not_now]
  end

  test "an unsubscribe classification adds the suppression the rule missed; never removes", ctx do
    put_env!(:fake_model_responder, UnsubscribeResponder)
    %{delivery: op, lead: lead} = delivered!(ctx)
    reply!(op, "Please do not write to this address again.")
    assert Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply)) == []

    assert %{success: 1} = classify!()

    [reply] = replies!(ctx)
    [decision] = decisions_about!(ctx, reply.id, :reply_classification)
    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))
    assert {suppression.decision_id, suppression.reply_id} == {decision.id, reply.id}
    assert reload!(ctx, lead).status == :stopped
  end

  test "when the rule already suppressed, the classification adds nothing", ctx do
    put_env!(:fake_model_responder, UnsubscribeResponder)
    %{delivery: op} = delivered!(ctx)
    reply!(op, "Unsubscribe me, please.")
    assert %{success: 1} = classify!()

    assert [suppression] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))
    [reply] = replies!(ctx)
    [rule] = decisions_about!(ctx, reply.id, :unsubscribe_rule)
    assert suppression.decision_id == rule.id
    assert [%{classification: :unsubscribe}] = assessments!(ctx)
  end

  test "an unmatched reply is not classified", ctx do
    %{delivery: op} = delivered!(ctx)

    assert {:ok, %{status: :accepted}} =
             ingest!(
               "reply",
               reply_body(op, "Who is this?",
                 from: "stranger@unknown.example.test",
                 in_reply_to: nil
               )
             )

    assert %{success: 1} = process!()
    refute_enqueued(worker: ReplyWorker)
  end

  describe "the assessment is bound to the model's validated classification" do
    setup ctx do
      %{delivery: op} = delivered!(ctx)
      reply!(op, "Thanks, this sounds interesting. Could we set up a call next week?")
      assert %{success: 1} = classify!()
      [reply] = replies!(ctx)
      [assessment] = assessments!(ctx)
      [decision] = decisions_about!(ctx, reply.id, :reply_classification)
      {:ok, run} = Agents.get_run(assessment.agent_run_id, actor: ctx.agent)
      %{reply: reply, decision: decision, run: run}
    end

    defp attrs(ctx, decision, overrides \\ %{}) do
      Map.merge(
        %{
          reply_id: ctx.reply.id,
          classification: :interested,
          sentiment: :positive,
          intent: "Reply classified as interested.",
          suggested_next_action: :hand_off,
          confidence: 0.85,
          reason: "The reply says \"call\".",
          agent_run_id: decision.agent_run_id,
          decision_id: decision.id,
          model_invocation_id: decision.model_invocation_id,
          supersedes_id: hd(assessments!(ctx)).id
        },
        overrides
      )
    end

    defp forge!(ctx, overrides) do
      {:ok, decision} =
        Agents.record_decision(
          Map.merge(
            %{
              kind: :reply_classification,
              mode: :llm,
              agent_run_id: ctx.run.id,
              subject_resource: "SdrAgent.Outreach.Reply",
              subject_id: ctx.reply.id,
              model_invocation_id: ctx.decision.model_invocation_id,
              output_pointer: "/classification",
              inputs: %{},
              outcome: "unsubscribe",
              idempotency_key: "forged:" <> Ecto.UUID.generate()
            },
            overrides
          ),
          actor: ctx.agent
        )

      decision
    end

    defp refused?(ctx, attrs) do
      assert {:error, %Ash.Error.Invalid{}} = Outreach.record_assessment(attrs, actor: ctx.agent)
      assert [_only_the_genuine_one] = assessments!(ctx)
      assert Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply)) == []
    end

    test "an outcome the model did not produce is refused (forged decision on a real call)",
         ctx do
      forged = forge!(ctx, %{})

      refused?(
        ctx,
        attrs(ctx, forged, %{classification: :unsubscribe, suggested_next_action: :stop})
      )
    end

    test "the genuine decision cannot back a different classification or values", ctx do
      refused?(ctx, attrs(ctx, ctx.decision, %{classification: :unsubscribe}))
      refused?(ctx, attrs(ctx, ctx.decision, %{sentiment: :negative}))
      refused?(ctx, attrs(ctx, ctx.decision, %{confidence: 0.99}))
    end

    test "a decision citing another run's or purpose's call is refused", ctx do
      %{run: research_run} = ctx.run |> Map.take([]) |> Map.put(:run, research_run!(ctx))

      [qualification] =
        invocations!(ctx, research_run) |> Enum.filter(&(&1.purpose == :qualification))

      forged =
        forge!(ctx, %{
          model_invocation_id: qualification.id,
          output_pointer: "/reason",
          outcome: "interested"
        })

      refused?(ctx, attrs(ctx, forged))
    end

    test "a decision about another resource or with another pointer is refused", ctx do
      wrong_resource =
        forge!(ctx, %{subject_resource: "SdrAgent.Sales.Lead", outcome: "interested"})

      refused?(ctx, attrs(ctx, wrong_resource))

      wrong_pointer = forge!(ctx, %{output_pointer: "/sentiment", outcome: "interested"})
      refused?(ctx, attrs(ctx, wrong_pointer))
    end
  end

  defp research_run!(ctx) do
    lead_id = ctx.run.lead_id

    {:ok, runs} =
      Agents.AgentRun
      |> Ash.Query.for_read(:read, %{}, actor: ctx.agent)
      |> Ash.Query.filter(lead_id == ^lead_id and trigger_signal_type == "sdr.lead.assigned")
      |> Ash.read()

    hd(runs)
  end

  test "assessments are written only by the agent", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Outreach.ReplyAssessment
             |> Ash.Changeset.for_create(
               :record,
               %{
                 reply_id: Ecto.UUID.generate(),
                 classification: :interested,
                 sentiment: :positive,
                 suggested_next_action: :hand_off,
                 confidence: 0.9,
                 agent_run_id: Ecto.UUID.generate(),
                 decision_id: Ecto.UUID.generate(),
                 model_invocation_id: Ecto.UUID.generate()
               },
               actor: ctx.admin
             )
             |> Ash.create()
  end
end

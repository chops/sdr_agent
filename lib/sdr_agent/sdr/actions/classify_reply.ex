defmodule SdrAgent.SDR.Actions.ClassifyReply do
  @moduledoc """
  `sdr.reply.received` (spec §6 Conversation: ClassifyReply, DetectInterest,
  DetectObjection — one structured call): classifies a matched reply with
  one model call returning a Zoi-validated ReplyAssessment (spec §16),
  records it as an LLM `reply_classification` Decision about the reply and
  writes the agent ReplyAssessment (`SdrAgent.Outreach.record_assessment/2`).

  The model classifies only. It drafts no response (owner decision
  2026-10-06: classify + hand off — the reply already stopped the sequence
  and put the lead in the hand-off queue) and it never decides suppression:
  the deterministic `unsubscribe_rule` already ran when the reply arrived;
  an `unsubscribe` classification can only *add* the same suppression
  (inside the assessment's transaction). A refused assessment fails the run
  as invalid model output.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_classify_reply",
    description:
      "ReplyAssessment of a matched reply (model, Zoi-validated); no drafted response.",
    schema:
      Zoi.object(%{
        reply_id: Zoi.string(),
        lead_id: Zoi.string() |> Zoi.optional(),
        campaign_id: Zoi.string() |> Zoi.optional(),
        enrollment_id: Zoi.string() |> Zoi.optional()
      })

  alias SdrAgent.Outreach
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model

  @impl SdrAgent.SDR.Action
  def perform(%{reply_id: reply_id}, ctx) do
    with {:ok, reply} <- Outreach.fetch(Outreach.Reply, reply_id, actor: ctx.actor),
         {:ok, output, invocation} <-
           Model.call(ctx, :reply_classification, input(reply), reply.lead_id),
         {:ok, decision} <- decide(ctx, reply, output, invocation) do
      attrs = %{
        reply_id: reply.id,
        classification: output.classification,
        sentiment: output.sentiment,
        intent: output.intent,
        suggested_next_action: output.suggested_next_action,
        confidence: output.confidence,
        reason: output.reason,
        agent_run_id: ctx.run_id,
        decision_id: decision.id,
        model_invocation_id: invocation.id
      }

      case Outreach.record_assessment(attrs, actor: ctx.actor) do
        {:ok, _assessment} ->
          {:ok, %{ctx.agent_state | phase: :reply}}

        {:error, _error} ->
          Model.halt_fail(ctx, nil, :invalid_model_output, "reply assessment refused")
      end
    end
  end

  defp input(reply), do: %{reply: %{subject: reply.subject || "", text: reply.body_text}}

  defp decide(ctx, reply, output, invocation) do
    Context.decide(
      ctx,
      %{
        kind: :reply_classification,
        mode: :llm,
        subject_resource: inspect(Outreach.Reply),
        subject_id: reply.id,
        model_invocation_id: invocation.id,
        output_pointer: "/classification",
        inputs: %{
          "reply_id" => reply.id,
          "body_sha256" => Base.encode16(reply.body_sha256, case: :lower)
        },
        outcome: output.classification,
        outcome_detail: %{
          "sentiment" => output.sentiment,
          "suggested_next_action" => output.suggested_next_action
        },
        rationale: output.reason,
        confidence: output.confidence
      },
      "classify:#{reply.id}",
      [reply]
    )
  end
end

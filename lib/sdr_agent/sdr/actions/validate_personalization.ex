defmodule SdrAgent.SDR.Actions.ValidatePersonalization do
  @moduledoc """
  PrepareOutreachFlow step "personalization" (deterministic): at least one
  personalization sentence, each citing an accepted evidence claim of this
  lead and appearing verbatim in the body. Records a
  `personalization_validation` Decision.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_validate_personalization",
    description: "Personalization must cite accepted evidence and appear in the body.",
    schema: Zoi.object(%{lead_id: Zoi.string(), draft: Zoi.map(), claims: Zoi.list(Zoi.map())})

  alias SdrAgent.SDR.Context

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, draft: draft, claims: evidence}, ctx) do
    validate(ctx, lead_id, draft, evidence, %{
      kind: :personalization_validation,
      rule: "sdr.personalization_cites_evidence",
      items: draft.proposal.personalization,
      text: & &1.text,
      minimum: 1
    })
  end

  @doc false
  def validate(ctx, lead_id, draft, evidence, rule) do
    accepted = MapSet.new(evidence, & &1.id)
    body = draft.proposal.body

    rejected =
      rule.items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        reasons =
          [
            not MapSet.member?(accepted, item.evidence_id) && "evidence_not_accepted_for_lead",
            not String.contains?(body, rule.text.(item)) && "text_not_in_body"
          ]
          |> Enum.filter(& &1)

        if reasons == [], do: [], else: [%{"index" => index, "reasons" => reasons}]
      end)

    too_few? = length(rule.items) < rule.minimum
    passed? = rejected == [] and not too_few?

    with {:ok, decision} <-
           Context.decide(
             ctx,
             %{
               kind: rule.kind,
               mode: :deterministic,
               rule_id: rule.rule,
               rule_version: "1",
               subject_id: lead_id,
               inputs: %{
                 "draft_proposal_decision_id" => draft.decision_id,
                 "model_invocation_id" => draft.model_invocation_id,
                 "accepted_evidence_ids" => MapSet.to_list(accepted)
               },
               outcome: if(passed?, do: "passed", else: "rejected"),
               outcome_detail: %{"rejected" => rejected, "too_few" => too_few?}
             },
             "validate"
           ) do
      {:ok, %{passed: passed?, decision_id: decision.id}}
    end
  end
end

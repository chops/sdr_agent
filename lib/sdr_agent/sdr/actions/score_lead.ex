defmodule SdrAgent.SDR.Actions.ScoreLead do
  @moduledoc """
  `sdr.qualification.requested`: one model call returning a Zoi-validated
  QualificationResult (spec §9) against the campaign's ICP version, over
  the lead's accepted evidence. The result is recorded as an LLM
  `qualification` Decision; evidence ids the model cites that are not
  accepted claims of this lead are dropped deterministically (and listed in
  the Decision). `SdrAgent.Research.record_qualification/2` then writes the
  Qualification and moves the lead to qualified/disqualified in one
  transaction; a result it refuses (e.g. qualified without accepted
  evidence) fails the run as invalid model output.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_score_lead",
    description: "QualificationResult over accepted evidence (model, Zoi-validated).",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx) do
    with {:ok, %{lead: lead, contact: contact, account: account}} <-
           Support.lead_context(ctx, lead_id),
         {:ok, campaign} <- Support.fetch(ctx, Sales.Campaign, ctx.agent_state.campaign_id),
         {:ok, icp} <- Support.fetch(ctx, Sales.IcpDefinition, campaign.icp_definition_id),
         {:ok, claims} <- Support.accepted_claims(ctx, lead_id),
         {:ok, output, invocation} <-
           Model.call(ctx, :qualification, input(icp, account, contact, claims), lead_id) do
      record(ctx, lead, icp, claims, output, invocation)
    end
  end

  defp input(icp, account, contact, claims) do
    criteria = icp.criteria

    %{
      icp: %{
        name: icp.name,
        version: icp.version,
        employee_count_min: criteria.employee_count_min,
        employee_count_max: criteria.employee_count_max,
        industries: criteria.industries,
        geographies: criteria.geographies,
        personas: criteria.personas,
        triggers: criteria.triggers
      },
      company: %{
        name: account.name,
        industry: account.industry,
        employee_count: account.employee_count,
        geography: account.geography
      },
      contact: %{title: contact.title, persona: contact.persona},
      evidence: Enum.map(claims, &%{id: &1.id, claim: &1.claim})
    }
  end

  defp record(ctx, lead, icp, claims, output, invocation) do
    accepted = MapSet.new(claims, & &1.id)
    {cited, dropped} = Enum.split_with(output.evidence_ids, &MapSet.member?(accepted, &1))

    with {:ok, decision} <-
           Context.decide(
             ctx,
             %{
               kind: :qualification,
               mode: :llm,
               subject_id: lead.id,
               model_invocation_id: invocation.id,
               output_pointer: "",
               inputs: %{
                 "icp_definition_id" => icp.id,
                 "accepted_evidence_ids" => MapSet.to_list(accepted)
               },
               outcome: if(output.qualified, do: "qualified", else: "disqualified"),
               outcome_detail: %{"score" => output.score, "dropped_evidence_ids" => dropped},
               rationale: output.reason,
               confidence: output.confidence
             },
             "score",
             [lead, icp]
           ) do
      attrs = %{
        lead_id: lead.id,
        icp_definition_id: icp.id,
        agent_run_id: ctx.run_id,
        decision_id: decision.id,
        qualified: output.qualified,
        score: output.score,
        criteria: output.criteria,
        confidence: output.confidence,
        reason: output.reason,
        output_schema_version: Schemas.version(),
        evidence_claim_ids: Enum.uniq(cited)
      }

      case Research.record_qualification(attrs, actor: ctx.actor) do
        {:ok, qualification} ->
          state =
            Map.put(ctx.agent_state, :qualification, %{
              id: qualification.id,
              qualified: qualification.qualified,
              score: qualification.score
            })

          {:ok, state,
           [
             Support.emit("sdr.qualification.completed", %{
               lead_id: lead.id,
               qualification_id: qualification.id,
               qualified: qualification.qualified
             })
           ]}

        {:error, _error} ->
          Model.halt_fail(ctx, nil, :invalid_model_output, "qualification result refused")
      end
    end
  end
end

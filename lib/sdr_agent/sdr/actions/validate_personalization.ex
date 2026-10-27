defmodule SdrAgent.SDR.Actions.ValidatePersonalization do
  @moduledoc """
  PrepareOutreachFlow step "personalization" (deterministic): at least one
  personalization sentence, each citing an accepted evidence claim of this
  lead and appearing verbatim in the body. Records a
  `personalization_validation` Decision.

  Version 2 (B1-R1 neighbor validators, plan
  `claude-b1-r1-neighbor-validators-delta-r1.md`; SDRAgent v5), shared with
  `ValidateClaims` through `validate/4`. After the run's pinned definition
  is checked to declare the executing action's version, it measures:

    * the authoritative draft (`SdrAgent.SDR.Support.authoritative_draft/3`),
      the same run/tenant/lead/Decision/invocation association and released
      output as the shape check. The caller's `draft.proposal` is never
      measured;
    * against the lead's accepted EvidenceClaims (`Support.accepted_claims/2`,
      a tenant-scoped domain read). The `claims` param is kept for the flow's
      wiring but is never the accepted set.

  The Decision records `input_refs` = the draft's `draft_proposal` Decision
  and ModelInvocation, so `HandOffProposal` can require it bound to the
  exact draft. Its inputs hold ids only and its outcome detail item indexes
  and reason codes only. The rules (membership, verbatim presence, the
  minimum count) are unchanged. A missing or mismatched pair, or an
  unreadable accepted set, stops the run `:crash` with a fixed,
  content-free reason before any Decision.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_validate_personalization",
    description: "Personalization must cite accepted evidence and appear in the body.",
    version: "2",
    schema: Zoi.object(%{lead_id: Zoi.string(), draft: Zoi.map(), claims: Zoi.list(Zoi.map())})

  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Preconditions
  alias SdrAgent.SDR.Support

  @no_accepted_evidence "the lead's accepted evidence is unavailable"

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, draft: draft}, ctx) do
    validate(ctx, lead_id, draft, %{
      action: __MODULE__,
      kind: :personalization_validation,
      rule: "sdr.personalization_cites_evidence",
      items: & &1.personalization,
      text: & &1.text,
      minimum: 1
    })
  end

  @doc false
  def validate(ctx, lead_id, draft, rule) do
    with :ok <- Preconditions.declared(ctx, rule.action),
         {:ok, %{decision: decision, invocation: invocation, proposal: proposal}} <-
           Support.authoritative_draft(ctx, lead_id, draft),
         {:ok, accepted} <- accepted(ctx, lead_id) do
      record(ctx, lead_id, rule, decision, invocation, proposal, accepted)
    end
  end

  defp accepted(ctx, lead_id) do
    case Support.accepted_claims(ctx, lead_id) do
      {:ok, claims} -> {:ok, MapSet.new(claims, & &1.id)}
      {:error, _error} -> Model.halt_fail(ctx, nil, :crash, @no_accepted_evidence)
    end
  end

  defp record(ctx, lead_id, rule, decision, invocation, proposal, accepted) do
    items = rule.items.(proposal)

    rejected =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        reasons =
          [
            not MapSet.member?(accepted, item.evidence_id) && "evidence_not_accepted_for_lead",
            not String.contains?(proposal.body, rule.text.(item)) && "text_not_in_body"
          ]
          |> Enum.filter(& &1)

        if reasons == [], do: [], else: [%{"index" => index, "reasons" => reasons}]
      end)

    too_few? = length(items) < rule.minimum
    passed? = rejected == [] and not too_few?

    with {:ok, check} <-
           Context.decide(
             ctx,
             %{
               kind: rule.kind,
               mode: :deterministic,
               rule_id: rule.rule,
               rule_version: "1",
               subject_id: lead_id,
               inputs: %{
                 "draft_proposal_decision_id" => decision.id,
                 "model_invocation_id" => invocation.id,
                 "accepted_evidence_ids" => MapSet.to_list(accepted)
               },
               outcome: if(passed?, do: "passed", else: "rejected"),
               outcome_detail: %{"rejected" => rejected, "too_few" => too_few?}
             },
             "validate",
             [decision, invocation]
           ) do
      {:ok, %{passed: passed?, decision_id: check.id}}
    end
  end
end

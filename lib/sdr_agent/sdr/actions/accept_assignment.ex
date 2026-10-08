defmodule SdrAgent.SDR.Actions.AcceptAssignment do
  @moduledoc """
  `sdr.lead.assigned`: decides deterministically whether the agent may work
  the lead — campaign active (`campaign_state_check`) and recipient not
  suppressed (`suppression_check`) — and records the `phase_transition`
  Decision. Proceeding moves the lead assigned → researching (citing that
  Decision) and emits `sdr.research.requested`; otherwise the assignment
  stops (phase `stop`) without any model call.

  A retried run (S13b, `SdrAgent.SDR.retry_run/2`) replays the assignment on
  a lead its failed predecessor already moved on: a lead already
  `researching` or `qualifying` is resumed — the Decision is still recorded
  (with the lead's status as an input) but the lead is not re-transitioned.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_accept_assignment",
    description: "Deterministic gates before research; starts the research phase.",
    schema: Zoi.object(%{lead_id: Zoi.string(), campaign_id: Zoi.string()})

  alias SdrAgent.Sales
  alias SdrAgent.SDR.Support

  @objective "Research and qualify the lead; prepare an evidence-grounded first touch for review."

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, campaign_id: campaign_id}, ctx) do
    with {:ok, %{lead: lead, contact: contact}} <- Support.lead_context(ctx, lead_id),
         {:ok, campaign} <- Support.fetch(ctx, Sales.Campaign, campaign_id),
         {:ok, campaign_check} <- Support.campaign_gate(ctx, campaign, lead_id, "accept"),
         {:ok, suppression} <- Support.suppression_gate(ctx, contact, lead_id, "accept") do
      proceed? = campaign_check.outcome == "active" and suppression.outcome == "not_suppressed"

      inputs = %{
        "lead_status" => Atom.to_string(lead.status),
        "campaign_state_check" => campaign_check.id,
        "suppression_check" => suppression.id
      }

      state = %{
        ctx.agent_state
        | lead_id: lead_id,
          campaign_id: campaign_id,
          objective: @objective
      }

      outcome = if proceed?, do: "research", else: "stop"

      with {:ok, decision} <-
             Support.phase_decision(ctx, lead_id, "accept", outcome, inputs, [lead]) do
        transition(outcome, lead, decision, state, ctx)
      end
    end
  end

  defp transition("research", lead, decision, state, ctx) do
    with {:ok, _lead} <- start_research(lead, decision, ctx) do
      {:ok, %{state | phase: :research},
       [Support.emit("sdr.research.requested", %{lead_id: lead.id})]}
    end
  end

  defp transition("stop", _lead, _decision, state, _ctx), do: {:ok, %{state | phase: :stop}}

  # Resuming a retried run: the lead already left `assigned`.
  defp start_research(%{status: status} = lead, _decision, _ctx)
       when status in [:researching, :qualifying],
       do: {:ok, lead}

  defp start_research(lead, decision, ctx),
    do: Sales.update(lead, :start_research, %{decision_id: decision.id}, actor: ctx.actor)
end

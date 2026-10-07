defmodule SdrAgent.SDR.Actions.RequestQualification do
  @moduledoc """
  `sdr.research.completed`: a deterministic `phase_transition` Decision on
  the evidence bundle. With at least one accepted claim the lead moves
  researching → qualifying and `sdr.qualification.requested` is emitted;
  without usable evidence the lead is blocked (which opens its
  operator-attention Failure in the same transaction) and the assignment
  stops.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_request_qualification",
    description: "Gate on accepted evidence before qualification.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.Sales
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx) do
    evidence = ctx.agent_state.evidence_ids

    with {:ok, lead} <- Support.fetch(ctx, Sales.Lead, lead_id) do
      inputs = %{
        "accepted_evidence_ids" => evidence,
        "lead_status" => Atom.to_string(lead.status)
      }

      outcome = if evidence != [], do: "qualify", else: "blocked"

      with {:ok, decision} <-
             Support.phase_decision(ctx, lead_id, "research_completed", outcome, inputs, [lead]) do
        transition(outcome, lead, decision, ctx)
      end
    end
  end

  defp transition("qualify", lead, decision, ctx) do
    with {:ok, _lead} <-
           Sales.update(lead, :start_qualifying, %{decision_id: decision.id}, actor: ctx.actor) do
      {:ok, %{ctx.agent_state | phase: :qualify},
       [Support.emit("sdr.qualification.requested", %{lead_id: lead.id})]}
    end
  end

  defp transition("blocked", lead, decision, ctx) do
    attrs = %{
      decision_id: decision.id,
      status_reason: "research found no accepted evidence",
      failure_class: :validation_error
    }

    with {:ok, _lead} <- Sales.update(lead, :block, attrs, actor: ctx.actor) do
      {:ok, %{ctx.agent_state | phase: :stop}}
    end
  end
end

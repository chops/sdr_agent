defmodule SdrAgent.SDR.Actions.HaltAssignment do
  @moduledoc """
  `sdr.lead.suppressed` and `sdr.campaign.paused`: ends the assignment
  deterministically (spec §8 — the model never decides suppression or
  campaign state). Records a `suppression_check` (outcome `suppressed`) or
  `campaign_state_check` (outcome `paused`) Decision citing the signal, and
  moves the agent to phase `stop`. Stopping the lead itself is the
  suppression side effect (S8) or an operator action — the agent may not
  stop a lead (S5 policy).
  """
  use SdrAgent.SDR.Action,
    name: "sdr_halt_assignment",
    description: "Stop the assignment on suppression or a paused campaign.",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string() |> Zoi.optional(),
        campaign_id: Zoi.string() |> Zoi.optional()
      })

  alias SdrAgent.SDR.Context

  @impl SdrAgent.SDR.Action
  def perform(_params, ctx) do
    {kind, outcome} =
      case ctx.signal_type do
        "sdr.lead.suppressed" -> {:suppression_check, "suppressed"}
        "sdr.campaign.paused" -> {:campaign_state_check, "paused"}
      end

    with {:ok, _decision} <-
           Context.decide(
             ctx,
             %{
               kind: kind,
               mode: :deterministic,
               rule_id: "sdr.halt_on_signal",
               rule_version: "1",
               subject_id: ctx.agent_state.lead_id,
               inputs: %{"signal_id" => ctx.signal_id, "signal_type" => ctx.signal_type},
               outcome: outcome
             },
             "halt:#{ctx.signal_id}"
           ) do
      {:ok, %{ctx.agent_state | phase: :stop}}
    end
  end
end

defmodule SdrAgent.SDR.Actions.PlanOutreach do
  @moduledoc """
  `sdr.qualification.completed`: a deterministic `phase_transition` Decision
  on the recorded Qualification. A qualified lead moves the agent to
  planning and emits `sdr.draft.requested`; a disqualified one ends the
  assignment (phase `stop`).
  """
  use SdrAgent.SDR.Action,
    name: "sdr_plan_outreach",
    description: "Route a qualified lead to outreach preparation.",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        qualification_id: Zoi.string(),
        qualified: Zoi.boolean()
      })

  alias SdrAgent.Research
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, qualification_id: id}, ctx) do
    with {:ok, qualification} <- Research.fetch(Research.Qualification, id, actor: ctx.actor) do
      inputs = %{"qualification_id" => id, "qualified" => qualification.qualified}
      outcome = if qualification.qualified, do: "plan", else: "stop"

      refs = [qualification]

      with {:ok, _decision} <-
             Support.phase_decision(
               ctx,
               lead_id,
               "qualification_completed",
               outcome,
               inputs,
               refs
             ) do
        next(outcome, lead_id, ctx)
      end
    end
  end

  defp next("plan", lead_id, ctx),
    do:
      {:ok, %{ctx.agent_state | phase: :plan},
       [Support.emit("sdr.draft.requested", %{lead_id: lead_id})]}

  defp next("stop", _lead_id, ctx), do: {:ok, %{ctx.agent_state | phase: :stop}}
end

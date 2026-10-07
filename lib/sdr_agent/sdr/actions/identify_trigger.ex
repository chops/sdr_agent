defmodule SdrAgent.SDR.Actions.IdentifyTrigger do
  @moduledoc """
  PrepareOutreachFlow step "trigger": selects the accepted evidence that
  names one of the ICP's buying triggers (case-insensitive phrase match);
  it is data selection for the draft, not a decision.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_identify_trigger",
    description: "Evidence naming an ICP buying trigger.",
    schema: Zoi.object(%{claims: Zoi.list(Zoi.map()), icp: Zoi.map()})

  @impl SdrAgent.SDR.Action
  def perform(%{claims: claims, icp: %{triggers: triggers}}, _ctx) do
    phrases = Enum.map(triggers, &String.downcase/1)

    matching =
      Enum.filter(claims, fn claim ->
        text = String.downcase(claim.claim)
        Enum.any?(phrases, &String.contains?(text, &1))
      end)

    {:ok, %{triggers: matching}}
  end
end

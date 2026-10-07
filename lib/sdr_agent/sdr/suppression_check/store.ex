defmodule SdrAgent.SDR.SuppressionCheck.Store do
  @moduledoc """
  The real suppression lookup (S8; replaces S7's `NoStore`): asks the
  Outreach store for suppressions of the email itself or of its domain, as
  the tenant's agent runtime. `suppressed` when any exists; the recorded
  Decision inputs name the store and the matching suppression ids and
  scopes. Lives in the agent plane, so the behaviour's dependency points
  down to Outreach, never up.
  """
  @behaviour SdrAgent.SDR.SuppressionCheck

  alias SdrAgent.Actor
  alias SdrAgent.Outreach

  @impl true
  def check(email, %{tenant_id: tenant_id}) do
    with {:ok, matches} <-
           Outreach.matching_suppressions(email, actor: Actor.system(:agent_runtime, tenant_id)) do
      verdict = if matches == [], do: :not_suppressed, else: :suppressed

      {:ok, verdict,
       %{
         "store" => "outreach",
         "suppression_ids" => Enum.map(matches, & &1.id),
         "scopes" => Enum.map(matches, &Atom.to_string(&1.scope))
       }}
    end
  end
end

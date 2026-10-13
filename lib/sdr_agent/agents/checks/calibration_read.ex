defmodule SdrAgent.Agents.Checks.CalibrationRead do
  @moduledoc """
  Field-policy filter check (R0-07 round 5, contract (c)): under the
  test-seam `SdrAgent.Agents.Checks.CalibrationContext`, AGT may read the
  output-bearing fields of exactly the bound proof invocation — that id,
  generation 2, `claude_cli`, the bound profile, a `:proof` run. Every other
  row, actor or build gets `false`.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias SdrAgent.Agents.Checks.CalibrationContext

  @impl true
  def describe(_opts), do: "the bound calibration proof invocation"

  @impl true
  def filter(%SdrAgent.Actor{type: :agent_runtime}, %{query: %{context: context}}, _opts) do
    case CalibrationContext.scope(context) do
      {profile_id, invocation_id} ->
        Ash.Expr.expr(
          id == ^invocation_id and profile_id == ^profile_id and ledger_generation == 2 and
            provider == :claude_cli and exists(agent_run, usage_origin == :proof)
        )

      nil ->
        Ash.Expr.expr(false)
    end
  end

  def filter(_actor, _context, _opts), do: Ash.Expr.expr(false)
end

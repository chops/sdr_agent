defmodule SdrAgent.JidoSpike.ScoreAction do
  @moduledoc "A minimal validated Jido action used only by the S1 compatibility spike."

  use Jido.Action,
    name: "s1_score_lead",
    schema: Zoi.object(%{score: Zoi.integer()})

  @impl true
  def run(%{score: score}, _context), do: {:ok, %{score: score}}
end

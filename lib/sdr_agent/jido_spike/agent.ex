defmodule SdrAgent.JidoSpike.Agent do
  @moduledoc "Minimal Jido AI agent proving action execution and structured fake-model output."

  use Jido.AI.Agent, name: "sdr_agent_s1_spike"

  agent do
    schema(
      Zoi.object(%{
        structured_output: Zoi.map() |> Zoi.default(%{})
      })
    )

    ai :assistant do
      model("openai:gpt-4o-mini")
      instructions("Score the lead with the declared tool, then return a structured decision.")

      tools do
        action SdrAgent.JidoSpike.ScoreAction, as: :score_lead
      end

      controls do
        timeout 5_000
        max_iterations 2
        max_model_calls(2)
        max_tool_calls(1)
      end

      result(
        Zoi.object(%{
          answer: Zoi.string() |> Zoi.min(1),
          score: Zoi.integer()
        }),
        into: :structured_output,
        max_repairs: 0
      )
    end
  end

  routes do
    signal_source("/sdr_agent/s1")

    route("sdr_agent.s1.qualify", ai: :assistant, as: :qualify)
  end
end

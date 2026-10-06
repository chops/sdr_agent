defmodule SdrAgent.JidoSpike do
  @moduledoc "Runs the deterministic S1 Jido v3 compatibility proof."

  alias Jido.AI.Test.MockLLM
  alias SdrAgent.JidoSpike.Agent

  @doc "Runs one action round followed by one Zoi-validated structured result."
  def run(script \\ default_script()) do
    jido = :"sdr_agent_s1_#{System.unique_integer([:positive])}"

    with {:ok, _jido} <- Jido.start(name: jido),
         {:ok, mock} <- MockLLM.start_link(script: script),
         {:ok, server} <- Jido.start_agent(jido, Agent.new!()),
         context = %{ai: %{assistant: %{options: MockLLM.options(mock)}}},
         {:ok, structured_output} <-
           Agent.ask_sync(server, "Qualify the fixture lead", context: context),
         %{structured_output: ^structured_output} <- Jido.AgentServer.agent(server).state,
         {:ok, action_result} <- action_result(MockLLM.report(mock)) do
      {:ok,
       %{
         action_result: action_result,
         structured_output: structured_output
       }}
    end
  end

  defp default_script do
    [
      %{
        reply:
          {:tools,
           [
             %{
               id: "score-call",
               name: "score_lead",
               arguments: %{score: 42}
             }
           ]}
      },
      %{reply: {:object, %{answer: "qualified", score: 42}}}
    ]
  end

  defp action_result(%{requests: [_first, second]}) do
    second.body["input"]
    |> Enum.find(&(&1["type"] == "function_call_output"))
    |> Map.fetch!("output")
    |> Jason.decode!()
    |> get_in(["result", "score"])
    |> then(&{:ok, &1})
  end

  defp action_result(_report), do: {:error, :action_result_not_observed}
end

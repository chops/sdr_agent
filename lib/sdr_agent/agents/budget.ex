defmodule SdrAgent.Agents.AgentRun.Budget do
  @moduledoc """
  Embedded per-run budget of an AgentRun (S2; ADR-0004): limits
  (`max_model_calls` 20, `max_tool_calls`, `max_tokens` 100 000) and
  counters (`model_calls_reserved`, `model_calls_used`, `tool_calls_used`,
  `tokens_used`). Counters only increase and change only through the
  AgentRun's atomic counter actions.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    for {name, default} <- [
          max_model_calls: 20,
          model_calls_reserved: 0,
          model_calls_used: 0,
          max_tool_calls: nil,
          tool_calls_used: 0,
          max_tokens: 100_000,
          tokens_used: 0
        ] do
      attribute name, :integer do
        allow_nil? false
        default default
        constraints min: 0
        public? true
      end
    end
  end
end

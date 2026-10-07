defmodule SdrAgent.Test.CaptureFaults do
  @moduledoc """
  Test-only fault plan for the capture adapter (`config :sdr_agent,
  :capture_faults, SdrAgent.Test.CaptureFaults`): each call of `fault/2`
  pops the next planned outcome for that phase (`:before_capture` or
  `:after_capture`) — `:ok`, `{:error, {class, reason}}` or `:crash`.
  Faults can only make a capture fail or look failed; they cannot reach
  anything outside the process.
  """
  use Agent

  @doc "Starts an empty plan (use with `start_supervised/1`)."
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Plans `outcomes` (in order) for `phase`."
  def plan(phase, outcomes), do: Agent.update(__MODULE__, &Map.put(&1, phase, outcomes))

  @doc "The next planned outcome for `phase` (`:ok` when none is planned)."
  def fault(phase, _operation) do
    Agent.get_and_update(__MODULE__, fn plan ->
      case Map.get(plan, phase, []) do
        [next | rest] -> {next, Map.put(plan, phase, rest)}
        [] -> {:ok, plan}
      end
    end)
  end
end

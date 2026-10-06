defmodule SdrAgent.Telemetry.SpanStore do
  @moduledoc false

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def put(spans, resource) do
    Agent.update(__MODULE__, fn stored -> Enum.map(spans, &{&1, resource}) ++ stored end)
  end

  def spans do
    Agent.get(__MODULE__, fn stored -> stored |> Enum.reverse() |> Enum.map(&elem(&1, 0)) end)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
end

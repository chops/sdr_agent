defmodule SdrAgent.Telemetry.InMemoryExporter do
  @moduledoc "Hermetic in-memory span exporter used by tests."

  @behaviour :otel_exporter
  @key {__MODULE__, :spans}

  def init(_config) do
    :persistent_term.put(@key, [])
    {:ok, nil}
  end

  def export(:traces, spans, resource, state) do
    exported = Enum.map(:ets.tab2list(spans), &{&1, resource})
    :persistent_term.put(@key, exported ++ :persistent_term.get(@key, []))

    _ = state
    :ok
  end

  def export(_signal, _items, _resource, _state), do: :ok
  def shutdown(_state), do: :ok

  def spans do
    @key |> :persistent_term.get([]) |> Enum.reverse() |> Enum.map(&elem(&1, 0))
  end

  def reset do
    :persistent_term.put(@key, [])
    :ok
  end
end

defmodule SdrAgent.Telemetry.InMemoryExporter do
  @moduledoc "Hermetic in-memory span exporter used by tests."

  @behaviour :otel_exporter
  alias SdrAgent.Telemetry.SpanStore

  def init(_config), do: {:ok, nil}

  def export(:traces, spans, resource, state) do
    SpanStore.put(:ets.tab2list(spans), resource)

    _ = state
    :ok
  end

  def export(_signal, _items, _resource, _state), do: :ok

  def export(spans, resource, state) do
    export(:traces, spans, resource, state)
  end

  def shutdown(_state), do: :ok

  def spans do
    SpanStore.spans()
  end

  def reset do
    SpanStore.reset()
  end
end

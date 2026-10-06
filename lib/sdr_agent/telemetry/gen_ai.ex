defmodule SdrAgent.Telemetry.GenAI do
  @moduledoc "Creates privacy-aware GenAI spans following `gen_ai.*` conventions."

  require OpenTelemetry.Tracer

  @content_keys [:input, :output]

  def with_span(operation, metadata, fun) when is_binary(operation) and is_map(metadata) do
    {attributes, events} = telemetry_payload(operation, metadata)

    OpenTelemetry.Tracer.with_span "gen_ai.#{operation}", attributes: attributes do
      Enum.each(events, fn {name, attrs} -> OpenTelemetry.Tracer.add_event(name, attrs) end)
      fun.()
    end
  end

  @doc false
  def telemetry_payload(operation, metadata) do
    {attributes(operation, metadata), content_events(metadata)}
  end

  defp attributes(operation, metadata) do
    base = %{"gen_ai.operation.name" => operation}

    Enum.reduce(metadata, base, fn
      {key, value}, acc when key in @content_keys and is_binary(value) ->
        acc
        |> Map.put("gen_ai.#{key}.id", Map.get(metadata, :id, "unknown"))
        |> Map.put("gen_ai.#{key}.sha256", sha256(value))

      {key, value}, acc
      when is_atom(key) and (is_binary(value) or is_number(value) or is_boolean(value)) ->
        Map.put(acc, "gen_ai.#{key}", value)

      _, acc ->
        acc
    end)
  end

  defp content_events(metadata) do
    if Application.get_env(:sdr_agent, :otel_capture_content, false) do
      Enum.flat_map(@content_keys, &content_event(&1, metadata[&1]))
    else
      []
    end
  end

  defp content_event(_key, nil), do: []

  defp content_event(key, content) do
    [{"gen_ai.#{key}.content", %{"gen_ai.#{key}.content" => content}}]
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end

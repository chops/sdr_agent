defmodule SdrAgent.Telemetry.GenAI do
  @moduledoc """
  Creates privacy-aware GenAI spans following `gen_ai.*` conventions.

  Span attributes carry identifiers and SHA-256 content hashes only. Prompt
  and completion bodies become `gen_ai.input.content` /
  `gen_ai.output.content` span events only when
  `:sdr_agent, :otel_capture_content` is true (development) *and* the
  metadata's `content_capture` is not `:off`. C4: a request whose input
  carries run settings is built with `content_capture: :off`, which
  dominates the configuration and any provider or request option; the span
  then records `gen_ai.content_capture` = `"off"` and no content event.
  """

  require OpenTelemetry.Tracer

  @content_keys [:input, :output]

  def with_span(operation, metadata, fun) when is_binary(operation) and is_map(metadata) do
    {attributes, events} = telemetry_payload(operation, metadata)

    OpenTelemetry.Tracer.with_span "gen_ai.#{operation}", attributes: attributes do
      Enum.each(events, fn {name, attrs} -> OpenTelemetry.Tracer.add_event(name, attrs) end)
      fun.()
    end
  end

  @doc """
  The W3C `traceparent` (version 00) of the current span, or `nil` when no
  valid span is active. The sampled flag is the context's own (`00`/`01`);
  ids are lowercase hex. Read in the calling process: the ClaudeCLI adapter
  forwards it so the local proxy can parent its witness span (ADR-0005 S12).
  """
  @spec traceparent() :: String.t() | nil
  def traceparent do
    case :otel_span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx()) do
      %{otel_trace_id: trace_id, otel_span_id: span_id, otel_trace_flags: flags} ->
        if valid_id?(trace_id, 32) and valid_id?(span_id, 16),
          do: "00-#{trace_id}-#{span_id}-#{flags}",
          else: nil

      _ ->
        nil
    end
  end

  defp valid_id?(hex, size) when is_binary(hex),
    do: byte_size(hex) == size and hex =~ ~r/\A[0-9a-f]+\z/ and hex != String.duplicate("0", size)

  defp valid_id?(_hex, _size), do: false

  @doc false
  def telemetry_payload(operation, metadata) do
    {attributes(operation, metadata), content_events(metadata)}
  end

  defp attributes(operation, metadata) do
    base = %{
      "gen_ai.operation.name" => operation,
      "gen_ai.content_capture" => Atom.to_string(content_capture(metadata))
    }

    Enum.reduce(metadata, base, fn
      {key, value}, acc when key in @content_keys and is_binary(value) ->
        acc
        |> Map.put("gen_ai.#{key}.id", Map.get(metadata, :id, "unknown"))
        |> Map.put("gen_ai.#{key}.sha256", sha256(value))

      {:content_capture, _value}, acc ->
        acc

      {key, value}, acc
      when is_atom(key) and (is_binary(value) or is_number(value) or is_boolean(value)) ->
        Map.put(acc, "gen_ai.#{key}", value)

      _, acc ->
        acc
    end)
  end

  defp content_events(metadata) do
    if content_capture(metadata) == :inherit and
         Application.get_env(:sdr_agent, :otel_capture_content, false) == true do
      Enum.flat_map(@content_keys, &content_event(&1, metadata[&1]))
    else
      []
    end
  end

  # Anything but an explicit `:inherit` (absent: the pre-C4 default) is off.
  defp content_capture(metadata) do
    case Map.get(metadata, :content_capture, :inherit) do
      :inherit -> :inherit
      _off -> :off
    end
  end

  defp content_event(_key, nil), do: []

  defp content_event(key, content) do
    [{"gen_ai.#{key}.content", %{"gen_ai.#{key}.content" => content}}]
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end

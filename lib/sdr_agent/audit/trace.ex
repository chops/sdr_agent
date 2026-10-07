defmodule SdrAgent.Audit.Trace do
  @moduledoc """
  OpenTelemetry correlation ids for persisted rows and audit events
  (ADR-0005, S2 "Trace correlation").

  Every row and every AuditEvent stores the lowercase-hex `trace_id` (32
  chars) and `span_id` (16 chars) of the span it was written in. When no
  valid span is active, the kernel opens one named `sdr.audit.append`, so no
  record class is untraced.
  """

  require OpenTelemetry.Tracer

  @span_name "sdr.audit.append"

  @doc "Runs `fun` inside the current span, or inside a new `sdr.audit.append` span if none is active."
  @spec with_span((-> result)) :: result when result: term()
  def with_span(fun) do
    if active?() do
      fun.()
    else
      OpenTelemetry.Tracer.with_span @span_name, %{kind: :internal} do
        fun.()
      end
    end
  end

  @doc "True when a valid span context is current."
  @spec active?() :: boolean()
  def active?, do: :otel_span.is_valid(OpenTelemetry.Tracer.current_span_ctx())

  @doc """
  `{trace_id, span_id}` for a row being written now: the current span's ids,
  or — if no span is active — those of a fresh `sdr.audit.append` span.
  """
  @spec row_ids() :: {String.t(), String.t()}
  def row_ids do
    if active?() do
      current_ids()
    else
      span_ctx = OpenTelemetry.Tracer.start_span(@span_name, %{kind: :internal})
      ids = {:otel_span.hex_trace_id(span_ctx), :otel_span.hex_span_id(span_ctx)}
      OpenTelemetry.Span.end_span(span_ctx)
      ids
    end
  end

  @doc """
  `{trace_id, span_id}` of the current span. Must be called inside
  `with_span/1` (or any active span); raises otherwise.
  """
  @spec current_ids() :: {String.t(), String.t()}
  def current_ids do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    if :otel_span.is_valid(span_ctx) do
      {:otel_span.hex_trace_id(span_ctx), :otel_span.hex_span_id(span_ctx)}
    else
      raise ArgumentError,
            "no active OpenTelemetry span; wrap the write in SdrAgent.Audit.Trace.with_span/1"
    end
  end
end

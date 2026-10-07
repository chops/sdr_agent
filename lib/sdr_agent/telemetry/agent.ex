defmodule SdrAgent.Telemetry.Agent do
  @moduledoc """
  Spans for the agent plane (ADR-0005: "custom spans for each Jido signal,
  action, flow, and agent run"): `sdr.agent.run`, `sdr.signal <type>` and
  `sdr.action <name>`, attributes carrying ids only (never content).

  Jido runs Flow steps in Task processes, which do not inherit the
  OpenTelemetry context; `current/0` captures it for the caller context and
  `with_context/2` re-attaches it, so every row a run writes shares the
  run's trace.
  """
  require OpenTelemetry.Tracer

  @doc "Runs `fun` inside a span named `name` with `attributes` (ids only)."
  def with_span(name, attributes, fun) when is_binary(name) and is_map(attributes) do
    OpenTelemetry.Tracer.with_span name, %{kind: :internal, attributes: attributes} do
      fun.()
    end
  end

  @doc "The current OpenTelemetry context, to hand to another process."
  def current, do: OpenTelemetry.Ctx.get_current()

  @doc "Runs `fun` with `ctx` attached (no-op for nil), restoring the previous context."
  def with_context(nil, fun), do: fun.()

  def with_context(ctx, fun) do
    token = OpenTelemetry.Ctx.attach(ctx)

    try do
      fun.()
    after
      OpenTelemetry.Ctx.detach(token)
    end
  end
end

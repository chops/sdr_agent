defmodule SdrAgent.Telemetry do
  @moduledoc "Runtime setup and client helpers for OpenTelemetry instrumentation."

  @setup_key {__MODULE__, :setup}

  def setup do
    unless :persistent_term.get(@setup_key, false) do
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit)
      OpentelemetryEcto.setup([:sdr_agent, :repo])
      OpentelemetryOban.setup()
      :persistent_term.put(@setup_key, true)
    end

    :ok
  end

  @doc "Attaches Req client tracing to a request or client template."
  def instrument_req(%Req.Request{} = request), do: OpentelemetryReq.attach(request)
end

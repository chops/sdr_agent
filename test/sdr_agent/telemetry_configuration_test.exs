defmodule SdrAgent.TelemetryConfigurationTest do
  use ExUnit.Case, async: true

  test "development alone enables OTLP/HTTP to loopback Tempo and content capture" do
    dev = File.read!("config/dev.exs")
    test = File.read!("config/test.exs")
    prod = File.read!("config/prod.exs")

    assert dev =~ ~s(otlp_endpoint: "http://127.0.0.1:4318")
    assert dev =~ "otel_capture_content: true"
    refute test =~ "127.0.0.1:4318"
    refute prod =~ "127.0.0.1:4318"
    assert test =~ "InMemoryExporter"
  end
end

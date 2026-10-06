defmodule SdrAgent.TelemetryTest do
  use ExUnit.Case, async: false

  alias SdrAgent.Telemetry.GenAI
  alias SdrAgent.Telemetry.InMemoryExporter

  setup do
    InMemoryExporter.reset()
    previous = Application.get_env(:sdr_agent, :otel_capture_content)

    on_exit(fn ->
      Application.put_env(:sdr_agent, :otel_capture_content, previous)
      InMemoryExporter.reset()
    end)

    :ok
  end

  test "test spans are exported in memory without network access" do
    assert InMemoryExporter == Application.fetch_env!(:sdr_agent, :otel_test_exporter)
    table = :ets.new(:test_spans, [:set, :public])
    :ets.insert(table, {:span, "in-memory"})
    assert :ok = InMemoryExporter.export(:traces, table, :resource, nil)
    assert [{:span, "in-memory"}] = InMemoryExporter.spans()
  end

  test "GenAI spans retain identifiers and hashes but omit content by default" do
    Application.put_env(:sdr_agent, :otel_capture_content, false)

    rendered =
      GenAI.telemetry_payload("chat", %{id: "inv-2", model: "fake", input: "secret prompt"})
      |> inspect(limit: :infinity)

    assert rendered =~ "gen_ai.operation.name"
    assert rendered =~ "gen_ai.input.sha256"
    assert rendered =~ "inv-2"
    refute rendered =~ "secret prompt"
  end

  test "content is recorded as events only behind the explicit capture switch" do
    Application.put_env(:sdr_agent, :otel_capture_content, true)

    rendered =
      GenAI.telemetry_payload("chat", %{id: "inv-3", input: "synthetic prompt"})
      |> inspect(limit: :infinity)

    assert rendered =~ "gen_ai.input.content"
    assert rendered =~ "synthetic prompt"
  end

  test "active spans publish trace and span IDs to Logger metadata" do
    GenAI.with_span("chat", %{id: "inv-4"}, fn ->
      metadata = :logger.get_process_metadata()
      assert is_binary(metadata.otel_trace_id)
      assert is_binary(metadata.otel_span_id)
    end)
  end

  test "all requested library instrumentations are configured" do
    assert Application.fetch_env!(:ash, :tracer) == [OpentelemetryAsh]
    assert %Req.Request{} = SdrAgent.Telemetry.instrument_req(Req.new())
    assert :ok = SdrAgent.Telemetry.setup()
  end
end

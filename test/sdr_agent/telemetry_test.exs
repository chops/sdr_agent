defmodule SdrAgent.TelemetryTest do
  use ExUnit.Case, async: false

  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Telemetry.GenAI
  alias SdrAgent.Telemetry.InMemoryExporter

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo)
    InMemoryExporter.reset()
    previous = Application.get_env(:sdr_agent, :otel_capture_content)

    on_exit(fn ->
      Application.put_env(:sdr_agent, :otel_capture_content, previous)
      InMemoryExporter.reset()
    end)

    :ok
  end

  test "SDK exports GenAI and instrumented Ecto child spans in memory" do
    assert InMemoryExporter == Application.fetch_env!(:sdr_agent, :otel_test_exporter)
    Application.put_env(:sdr_agent, :otel_capture_content, false)

    GenAI.with_span("chat", %{id: "inv-sdk", input: "sdk secret"}, fn ->
      metadata = :logger.get_process_metadata()
      send(self(), {:logger_metadata, metadata})
      SQL.query!(SdrAgent.Repo, "SELECT 1", [])
    end)

    assert_receive {:logger_metadata, metadata}
    assert metadata.otel_trace_id =~ ~r/^[0-9a-f]{32}$/
    assert metadata.otel_span_id =~ ~r/^[0-9a-f]{16}$/

    spans = eventually_spans(2)
    gen_ai = Enum.find(spans, &(span(&1, :name) == "gen_ai.chat"))
    ecto = Enum.find(spans, &(span(&1, :name) != "gen_ai.chat"))

    assert gen_ai
    assert ecto
    assert span(ecto, :trace_id) == span(gen_ai, :trace_id)
    assert span(ecto, :parent_span_id) == span(gen_ai, :span_id)

    rendered = inspect(gen_ai, limit: :infinity)
    assert rendered =~ "gen_ai.input.sha256"
    assert rendered =~ "inv-sdk"
    refute rendered =~ "sdk secret"
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

    GenAI.with_span("chat", %{id: "inv-content", input: "synthetic prompt"}, fn -> :ok end)
    span = eventually_spans(1) |> Enum.find(&(span(&1, :name) == "gen_ai.chat"))
    assert inspect(span, limit: :infinity) =~ "synthetic prompt"
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

  defp eventually_spans(minimum, attempts \\ 50)
  defp eventually_spans(_minimum, 0), do: flunk("spans were not exported through the SDK")

  defp eventually_spans(minimum, attempts) do
    spans = InMemoryExporter.spans()

    if length(spans) >= minimum do
      spans
    else
      Process.sleep(10)
      eventually_spans(minimum, attempts - 1)
    end
  end
end

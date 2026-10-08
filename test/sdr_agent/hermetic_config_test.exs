defmodule SdrAgent.HermeticConfigTest do
  @moduledoc """
  Local hermetic proof (S13; checklist 4.2). CI runs the whole gate in a
  loopback-only network namespace (ADR-0007); this test asserts locally
  that the test environment is wired to in-process stand-ins only, so no
  test can reach the network through configuration: the fake model, no
  anchor sinks, the in-memory span exporter, the Swoosh test adapter with no
  HTTP client, the capture-only delivery adapter, an endpoint without a
  listener, and no outbound URLs in the runtime configuration.
  """
  use ExUnit.Case, async: true

  test "providers and exporters are in-process stand-ins" do
    assert Application.get_env(:sdr_agent, :model_provider) == SdrAgent.AI.ModelProvider.Fake
    assert Application.get_env(:sdr_agent, :anchor_sinks) == []

    assert Application.get_env(:sdr_agent, :otel_test_exporter) ==
             SdrAgent.Telemetry.InMemoryExporter

    assert Application.get_env(:sdr_agent, SdrAgent.Mailer)[:adapter] == Swoosh.Adapters.Test
    assert Application.get_env(:swoosh, :api_client) == false
    assert SdrAgent.Outreach.Delivery.adapter() == SdrAgent.Outreach.Delivery.CaptureAdapter
    assert Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint)[:server] == false
  end

  test "no runtime configuration value points at a non-local host" do
    urls =
      for {app, _, _} <- Application.loaded_applications(),
          app in [:sdr_agent, :opentelemetry, :opentelemetry_exporter, :swoosh],
          {_key, value} <- Application.get_all_env(app),
          url <- strings(value),
          String.match?(url, ~r{\A(https?|wss?)://}i),
          not local?(url),
          do: {app, url}

    assert urls == []
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> strings()
  defp strings(value) when is_tuple(value), do: value |> Tuple.to_list() |> strings()
  defp strings(_value), do: []

  defp local?(url) do
    %URI{host: host} = URI.parse(url)
    host in ["localhost", "127.0.0.1", "::1"] or String.ends_with?(host || "", ".test")
  end
end

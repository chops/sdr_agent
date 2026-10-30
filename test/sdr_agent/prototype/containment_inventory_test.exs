# DRAFT r4 (outside the repository; review only; NOT formatted, compiled or
# run). SOURCE-READING static inventory: it READS source files (lib/**/*.ex
# and dependency sources under Mix.Project.deps_path/0). It reads no VM
# state and calls no Containment function. It is not a pure test.
defmodule SdrAgent.Prototype.ContainmentInventoryTest do
  @moduledoc """
  Containment r4 PS-M: every call site that can add or change a telemetry
  handler, a Logger filter or handler, an SDK tracer or provider, or the
  application or OS environment is in the reviewed inventory.

  STRUCTURAL CONTROL: it is expected to PASS at the RED head (the counts
  below are the S4 RED head 709e3030 source, with S1b TaskBoundary step 5
  at task_boundary.ex, and the locked dependencies). It
  earns no TDD credit; it fails on any new or removed call site, which then
  needs review. Inventory counts are per file, by the patterns below.
  """
  use ExUnit.Case, async: true

  @lib_pattern ~r/:telemetry\.attach(_many)?\(|:logger\.(add_primary_filter|add_handler|add_handler_filter|set_primary_config|set_handler_config|update_primary_config|update_handler_config|remove_primary_filter|remove_handler)\(|:opentelemetry\.(set_tracer|set_default_tracer|start_tracer_provider)\(|Application\.put_env\(|System\.put_env\(|Opentelemetry[A-Za-z]*\.setup\(|Logger\.(add_backend|configure|put_module_level|put_application_level)\(/
  @lib %{
    "lib/mix/tasks/sdr.demo.predeliver.ex" => 1,
    "lib/mix/tasks/sdr.demo.reply.ex" => 1,
    "lib/mix/tasks/sdr.demo.serve.ex" => 5,
    "lib/mix/tasks/sdr.demo.status.ex" => 1,
    # D-268 M7: serve-only fixed endpoint override (4120, server: true)
    # after guard and preflight; app env only, no handler or sink.
    "lib/mix/tasks/sdr.prototype.serve.ex" => 1,
    "lib/sdr_agent/calibration_console.ex" => 8,
    "lib/sdr_agent/logger/exception_filter.ex" => 2,
    # ADR-0022: exact ssl_handler formatter-only setter, no new sink.
    "lib/sdr_agent/prototype/launch_prelude.ex" => 1,
    "lib/sdr_agent/prototype/safe_log.ex" => 2,
    "lib/sdr_agent/prototype/task_boundary.ex" => 1,
    "lib/sdr_agent/repo/query_log.ex" => 1,
    "lib/sdr_agent/telemetry.ex" => 3,
    "lib/sdr_agent/telemetry/repo_spans.ex" => 1
  }
  @dep_pattern ~r/:telemetry\.attach(_many)?\(|telemetry:attach(_many)?\(|:logger\.add_handler\(|:logger\.add_primary_filter\(|logger:add_handler\(|logger:add_primary_filter\(/
  # Class: :app_start (runs at its application's start, before G1),
  # :user_invoked (only when called; no lib call), :test_only, :doc_only,
  # :dev_tool (a Mix tool not started by any prototype entry).
  @deps %{
    "ash/lib/ash/signals/test.ex" => {2, :test_only},
    "bandit/lib/bandit/trace.ex" => {1, :user_invoked},
    "ecto/lib/ecto/repo.ex" => {1, :doc_only},
    "igniter/lib/igniter/util/capture_server.ex" => {2, :dev_tool},
    "jido/lib/jido/telemetry.ex" => {1, :app_start},
    "oban/lib/oban/telemetry.ex" => {3, :user_invoked},
    "opentelemetry_bandit/lib/opentelemetry_bandit.ex" => {1, :user_invoked},
    "opentelemetry_ecto/lib/opentelemetry_ecto.ex" => {1, :user_invoked},
    "opentelemetry_oban/lib/opentelemetry_oban/job_handler.ex" => {3, :user_invoked},
    "opentelemetry_oban/lib/opentelemetry_oban/plugin_handler.ex" => {3, :user_invoked},
    "opentelemetry_phoenix/lib/opentelemetry_phoenix.ex" => {3, :user_invoked},
    "owl/lib/owl/live_screen.ex" => {1, :dev_tool},
    "phoenix/lib/phoenix/logger.ex" => {1, :app_start},
    "phoenix_live_dashboard/lib/phoenix/live_dashboard/application.ex" => {1, :app_start},
    "phoenix_live_dashboard/lib/phoenix/live_dashboard/telemetry_listener.ex" =>
      {1, :user_invoked},
    "phoenix_live_reload/lib/phoenix_live_reload/web_console_logger.ex" => {1, :user_invoked},
    "phoenix_live_view/lib/phoenix_live_view/logger.ex" => {1, :app_start},
    "req/lib/req/test.ex" => {1, :test_only},
    "req_llm/lib/req_llm/open_telemetry.ex" => {1, :user_invoked},
    "swoosh/lib/swoosh/mailer.ex" => {1, :doc_only},
    "telemetry/src/telemetry_test.erl" => {1, :test_only},
    "telemetry_metrics/lib/telemetry_metrics/console_reporter.ex" => {1, :user_invoked},
    "thousand_island/lib/thousand_island/logger.ex" => {4, :user_invoked},
    "tidewave/lib/mix/tasks/tidewave.proxy.ex" => {1, :dev_tool},
    "tidewave/lib/tidewave/mcp.ex" => {1, :app_start}
  }
  # The user-invoked dependency entry points that lib must never call.
  @forbidden_entry ~r/OpentelemetryOban\.setup|OpentelemetryEcto\.setup|ReqLLM\.OpenTelemetry\.attach|Oban\.Telemetry\.attach_default_logger|ThousandIsland\.Logger\.attach_logger|Bandit\.Trace|TelemetryMetrics\.ConsoleReporter|Telemetry\.Metrics\.ConsoleReporter|attach_logger/

  test "lib: every mutator call site is in the reviewed inventory" do
    found =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map(&{&1, count(&1, @lib_pattern)})
      |> Enum.reject(fn {_path, n} -> n == 0 end)
      |> Map.new()

    assert found == @lib, "the lib mutator inventory differs from the reviewed one"
  end

  test "deps: every dependency adder site is in the reviewed inventory" do
    root = Mix.Project.deps_path()

    found =
      Path.join(root, "**/*.{ex,erl}")
      |> Path.wildcard()
      |> Enum.reject(&(String.contains?(&1, "/test/") or String.contains?(&1, "/examples/")))
      |> Enum.map(&{Path.relative_to(&1, root), count(&1, @dep_pattern)})
      |> Enum.reject(fn {_path, n} -> n == 0 end)
      |> Map.new()

    assert found == Map.new(@deps, fn {path, {n, _class}} -> {path, n} end),
           "the dependency adder inventory differs from the reviewed one"
  end

  test "lib calls no user-invoked dependency attacher" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> String.match?(@forbidden_entry)))
      |> Enum.sort()

    # The two reviewed matches: lib/sdr_agent/telemetry.ex's gated vendor
    # setups (CC1; OpentelemetryOban.setup at :22) and the COMMENTED-OUT
    # ConsoleReporter line at lib/sdr_agent_web/telemetry.ex:16 (a text
    # match, not a call).
    assert offenders == ["lib/sdr_agent/telemetry.ex", "lib/sdr_agent_web/telemetry.ex"],
           "lib calls a user-invoked dependency attacher outside the reviewed exceptions"
  end

  defp count(path, pattern),
    do: path |> File.read!() |> then(&Regex.scan(pattern, &1)) |> length()
end

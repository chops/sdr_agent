# DRAFT r4a (outside the repository; review only; NOT formatted, compiled
# or run). PURE scope: no VM state, no I/O, no VM-effect API.
defmodule SdrAgent.Prototype.ContainmentConfigTest do
  @moduledoc """
  Containment r4 PS-K (the K0/K-block check), PS-Q (the K7 paused queue
  list, from injected queue data) and the kind/code/phase constants.

  RED (deny-only declarations): every test fails at its first assertion
  with its fixed message; later rows of a table are unexecuted.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Containment

  @kinds [:setup, :provision, :import, :op, :serve]
  @codes [
    :entry_unadopted,
    :otel_env,
    :crash_dump_env,
    :phx_server_env,
    :tracer_noop,
    :tracer_sampler,
    :tracer_processor,
    :tracer_provider,
    :sdk_tree,
    :tree,
    :endpoint_present,
    :applications,
    :handler_forbidden,
    :handler_closure,
    :handlers,
    :logger_filters,
    :logger_handlers,
    :ash_tracer,
    :distributed,
    :listener_present,
    :listener_unknown,
    :anchor_sinks,
    :descriptor_unknown,
    :descriptor_unbounded,
    :snapshot_failed,
    :seal_exists,
    :seal_absent,
    :seal_phase,
    :seal_mismatch
  ]
  # Synthetic .test values only.
  @clean %{
    "PATH" => "/usr/bin:/bin",
    "HOME" => "/Users/someone.test",
    "ERL_CRASH_DUMP_BYTES" => "0",
    "otel_lowercase_is_not_the_prefix" => "1"
  }
  # The queue limits of config/config.exs (S4 09ad3ce :19-27), injected as
  # data: this test reads no file.
  @queues [
    default: 10,
    research: 20,
    delivery: 5,
    reconciliation: 1,
    followup: 10,
    integration: 5,
    agent: 10
  ]

  test "the kinds and the closed code family, in check order" do
    assert Containment.kinds() == @kinds, "the kinds are not the reviewed five"
    assert Containment.codes() == @codes, "the code family is not the reviewed list"
  end

  test "the pinned phase sequences" do
    assert Containment.phases(:setup) == [:sealed, :maintenance, :storage, :repo, :retained],
           "setup's phase sequence is not the reviewed one"

    for kind <- [:provision, :import, :op, :serve] do
      assert Containment.phases(kind) == [:sealed], "#{kind} has a phase beyond :sealed"
    end
  end

  test "config_check: a clean environment is accepted for every adopted kind" do
    for kind <- @kinds do
      assert Containment.config_check(@clean, kind) == :ok,
             "a clean environment was refused for #{kind}"
    end
  end

  test "config_check: each refusal, first failure in code order" do
    rows = [
      {@clean, nil, :entry_unadopted},
      {@clean, :export, :entry_unadopted},
      {@clean, "serve", :entry_unadopted},
      {Map.put(@clean, "OTEL_SDK_DISABLED", "true"), nil, :entry_unadopted},
      {Map.put(@clean, "OTEL_SDK_DISABLED", "true"), :serve, :otel_env},
      {Map.put(@clean, "OTEL_TRACES_EXPORTER", "none"), :op, :otel_env},
      {Map.put(@clean, "OTEL_", ""), :setup, :otel_env},
      {Map.delete(@clean, "ERL_CRASH_DUMP_BYTES"), :serve, :crash_dump_env},
      {Map.put(@clean, "ERL_CRASH_DUMP_BYTES", "1"), :serve, :crash_dump_env},
      {Map.put(@clean, "ERL_CRASH_DUMP_BYTES", " 0"), :serve, :crash_dump_env},
      {Map.put(@clean, "PHX_SERVER", ""), :serve, :phx_server_env},
      {Map.put(@clean, "PHX_SERVER", "true"), :import, :phx_server_env},
      {Map.merge(@clean, %{"OTEL_X" => "1", "PHX_SERVER" => "1"}), :serve, :otel_env},
      {:not_a_map, :serve, :descriptor_unknown}
    ]

    for {{env, entry, code}, index} <- Enum.with_index(rows) do
      assert Containment.config_check(env, entry) == {:error, code},
             "config row #{index} was not refused as #{code}"
    end
  end

  test "paused_queues: every configured queue keeps its limit and starts paused" do
    assert Containment.paused_queues(@queues) == [
             default: [limit: 10, paused: true],
             research: [limit: 20, paused: true],
             delivery: [limit: 5, paused: true],
             reconciliation: [limit: 1, paused: true],
             followup: [limit: 10, paused: true],
             integration: [limit: 5, paused: true],
             agent: [limit: 10, paused: true]
           ],
           "the paused queue list is not the configured limits, paused"
  end

  test "paused_queues: a malformed queue list is refused" do
    rows = [[], [default: 0], [default: "10"], [{"default", 10}], [default: 10, default: 5], :none]

    for {queues, index} <- Enum.with_index(rows) do
      assert Containment.paused_queues(queues) == {:error, :descriptor_unknown},
             "queue row #{index} was not refused"
    end
  end
end

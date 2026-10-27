defmodule SdrAgent.AI.ClaudeCLIEffectiveTimeoutTest do
  @moduledoc """
  C2* S3 RED-5, OQ10 (S3 plan r2 §6 ClaudeCLI; Codex r2 review, OQ7
  qualification: the lookup is non-blocking metadata, with named, pid,
  missing, stopped and longer cases). The demo-exception launch margin's T
  is the same validated startup timeout the provider runs.

    * `ClaudeCLI.effective_timeout/1` reads the `:timeout` a running server
      published at start. For a registered name it is an ETS lookup; for a
      pid, the published key. It is nil when the server is not running.
      It never messages or waits on the server.
    * `DemoException.provider_timeout_ms/1` is that value. With no running
      server it is the configured `:timeout` (`config :sdr_agent,
      SdrAgent.AI.ModelProvider.ClaudeCLI`, the value
      `Runtime.server_options/1` passes the app's server), when that is an
      integer of at least 1000 (the server's own rule). Otherwise it is
      240_000, never the module's 120_000 default.

  Cases: named; pid; unnamed; missing (and a live process that is no
  server); stopped; a suspended server (the lookup does not wait); the
  running value over a shorter and over a longer configuration; the
  configured value; invalid configurations; neither.

  Classification (RED-5 at b30364b9): structural (both functions are
  absent).
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.DemoException
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.LaunchAdmission

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    saved = Application.fetch_env(:sdr_agent, ClaudeCLI)
    Application.delete_env(:sdr_agent, ClaudeCLI)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:sdr_agent, ClaudeCLI, value)
        :error -> Application.delete_env(:sdr_agent, ClaudeCLI)
      end
    end)

    :ok
  end

  describe "ClaudeCLI.effective_timeout/1" do
    test "a named server's published timeout is read by name and by pid" do
      name = unique_name()
      pid = start!(name: name, timeout: 300_000)
      assert effective_timeout(name) == 300_000
      assert effective_timeout(pid) == 300_000
    end

    test "an unnamed server's published timeout is read by pid" do
      pid = start!(timeout: 45_000)
      assert effective_timeout(pid) == 45_000
    end

    test "a missing server, or a live process that is no server, reads nil" do
      assert effective_timeout(unique_name()) == nil
      assert effective_timeout(self()) == nil
    end

    test "a stopped server reads nil by name and by pid" do
      name = unique_name()
      {:ok, pid} = ClaudeCLI.start_link(opts(name: name, timeout: 300_000))
      assert effective_timeout(name) == 300_000
      :ok = GenServer.stop(pid)
      assert effective_timeout(name) == nil
      assert effective_timeout(pid) == nil
    end

    test "the lookup never waits on the server: a suspended server still answers" do
      name = unique_name()
      pid = start!(name: name, timeout: 300_000)
      assert effective_timeout(name) == 300_000
      :ok = :sys.suspend(pid)

      try do
        lookup = Task.async(fn -> {effective_timeout(name), effective_timeout(pid)} end)
        assert Task.yield(lookup, 2_000) == {:ok, {300_000, 300_000}}
      after
        :sys.resume(pid)
      end
    end
  end

  describe "DemoException.provider_timeout_ms/1" do
    test "the running server's value wins over a shorter configuration (longer)" do
      configure!(240_000)
      name = unique_name()
      start!(name: name, timeout: 300_000)
      assert provider_timeout_ms(name) == 300_000
    end

    test "the running server's value wins over a longer configuration" do
      configure!(300_000)
      name = unique_name()
      pid = start!(name: name, timeout: 200_000)
      assert provider_timeout_ms(name) == 200_000
      assert provider_timeout_ms(pid) == 200_000
    end

    test "with no running server the configured timeout applies, as the app's server gets it" do
      configure!(300_000)
      assert Keyword.get(Runtime.server_options(:claude_cli_opus), :timeout) == 300_000
      assert provider_timeout_ms(unique_name()) == 300_000
      configure!(1_000)
      assert provider_timeout_ms(unique_name()) == 1_000
    end

    test "a stopped server falls back to the configuration, else 240_000" do
      name = unique_name()
      {:ok, pid} = ClaudeCLI.start_link(opts(name: name, timeout: 300_000))
      :ok = GenServer.stop(pid)
      assert provider_timeout_ms(name) == 240_000
      configure!(280_000)
      assert provider_timeout_ms(name) == 280_000
    end

    test "an invalid configuration is ignored: 240_000" do
      for value <- [999, 0, -1, "300000", 300_000.0, nil] do
        configure!(value)
        assert provider_timeout_ms(unique_name()) == 240_000, inspect(value)
      end
    end

    test "neither a running server nor a configuration: 240_000, never the module's 120_000" do
      assert Application.fetch_env(:sdr_agent, ClaudeCLI) == :error
      assert provider_timeout_ms(unique_name()) == 240_000
      refute provider_timeout_ms(unique_name()) == 120_000
    end
  end

  ## Harness

  defp effective_timeout(server) do
    assert Code.ensure_loaded?(ClaudeCLI) and function_exported?(ClaudeCLI, :effective_timeout, 1),
           "C2* S3 OQ10: ClaudeCLI.effective_timeout/1 is absent"

    call(ClaudeCLI, :effective_timeout, [server])
  end

  defp provider_timeout_ms(server) do
    assert Code.ensure_loaded?(DemoException) and
             function_exported?(DemoException, :provider_timeout_ms, 1),
           "C2* S3 OQ10: DemoException.provider_timeout_ms/1 is absent"

    call(DemoException, :provider_timeout_ms, [server])
  end

  defp call(module, function, args), do: apply(module, function, args)

  defp configure!(timeout), do: Application.put_env(:sdr_agent, ClaudeCLI, timeout: timeout)

  defp unique_name, do: :"sdr-demo-timeout-#{System.unique_integer([:positive])}"

  # An idle hermetic server (no call is made).
  defp start!(extra) do
    start_supervised!(Supervisor.child_spec({ClaudeCLI, opts(extra)}, id: make_ref()))
  end

  defp opts(extra) do
    [
      command: System.find_executable("elixir"),
      test_launcher: true,
      launch_admission: &LaunchAdmission.admitted/3,
      command_args: [@fake, "ready"]
    ] ++ extra
  end
end

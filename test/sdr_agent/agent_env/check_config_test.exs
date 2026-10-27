defmodule SdrAgent.AgentEnv.CheckConfigTest do
  @moduledoc """
  C2* S1 PR-B RED-3 correction (Codex `b684dba9` M2): the real default P0
  check VM's resolved configuration.

  `bin/agent-env` runs `mix sdr.agent_env check run|provision` with
  `MIX_ENV=dev`, `SDR_AGENT_ENV=agentenv-1`, `SDR_AGENT_ENV_STEP=check`,
  no nonce and, by default, no `PORT`. That VM's configuration is
  `config/config.exs` (dev, importing `config/dev.exs`) followed by
  `config/runtime.exs`; these tests compose exactly those files with
  `Config.Reader`, as Mix does, under that environment: no application
  start, lease, Repo or database, and no hand-built inputs map.

  `Launcher.check/1` requires the resolved Endpoint HTTP to be
  `127.0.0.1:4130`. `config/dev.exs` declares `127.0.0.1:4120` and
  `config/runtime.exs` overrides the port only for a set `PORT`, so check
  mode must publish the inert fixed tuple itself: `http: [ip: {127, 0, 0,
  1}, port: 4130]` with `server: false` (GREEN-3, `Boot`'s check-mode
  configuration), while `Boot.check_start!/0` and the Repo's supervisor
  start still refuse check mode. The stub call lines and port rules of
  `bin/agent-env` stay unchanged.

  RED: check mode publishes no Endpoint configuration, so with `PORT` unset
  the declared dev port 4120 survives (behavioural); `Launcher` does not
  exist (structural, guarded after the composition). The explicit
  `PORT=4130`, inert-dev, Repo-target and start-refusal controls execute
  now.
  """
  # The composition reads the OS environment (System.get_env/0).
  use ExUnit.Case, async: false

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Boot
  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx

  @launcher SdrAgent.AgentEnv.Launcher
  @config_dir Path.expand("../../../config", __DIR__)
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]

  setup do
    %{home: home, root: root} = BootFx.home!()

    for dir <- @subdirectories do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    BootFx.preserve_app_env!(:sdr_agent)
    %{home: home, root: root}
  end

  ## Helpers

  # The OS environment of bin/agent-env's check VM (no lease, no nonce).
  defp check_vm_env(ctx, overrides) do
    Map.merge(
      %{
        "HOME" => ctx.home,
        "SDR_AGENT_ENV" => "agentenv-1",
        "SDR_AGENT_ENV_STEP" => "check",
        "SDR_AGENT_ENV_NONCE" => nil,
        "PORT" => nil,
        "PHX_SERVER" => nil,
        "DATABASE_URL" => nil,
        "SDR_MODEL_PROVIDER" => nil,
        "SDR_DEMO_EXCEPTION" => nil,
        "SDR_WITNESS_STORE_ROOT" => Path.join(ctx.root, "evidence"),
        "SDR_ANCHOR_SINKS" => "file",
        "SDR_ANCHOR_FILE_DIR" => Path.join(ctx.root, "anchors")
      },
      overrides
    )
  end

  # config/config.exs (dev) then config/runtime.exs, under `os_env`.
  defp composed!(os_env) do
    BootFx.put_os_env!(os_env)
    compile = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :dev, target: :host)
    runtime = Config.Reader.read!(Path.join(@config_dir, "runtime.exs"), env: :dev, target: :host)
    Config.Reader.merge(compile, runtime)
  end

  defp sdr(config), do: Keyword.fetch!(config, :sdr_agent)
  defp endpoint(config), do: config |> sdr() |> Keyword.fetch!(SdrAgentWeb.Endpoint)
  defp http(config), do: config |> endpoint() |> Keyword.fetch!(:http)

  # Launcher.check/1's inputs from the composed configuration's own values.
  defp launcher_inputs(ctx, config) do
    sdr = sdr(config)
    build = Path.join([ctx.root, "build", "dev"])
    File.mkdir_p!(build)

    %{
      intent: :run,
      env: %{},
      root: ctx.root,
      build_path: build,
      deps_path: Path.join(ctx.root, "deps"),
      config: %{
        repo: Keyword.fetch!(sdr, SdrAgent.Repo),
        endpoint_http: http(config),
        anchor_sinks: Keyword.fetch!(sdr, :anchor_sinks),
        witness_store_root:
          sdr |> Keyword.fetch!(SdrAgent.Agents.Witness) |> Keyword.get(:store_root),
        suppression_check: Keyword.fetch!(sdr, :suppression_check),
        otel_capture_content: Keyword.fetch!(sdr, :otel_capture_content)
      },
      connect: fn _ip, _port -> {:error, :econnrefused} end
    }
  end

  defp refused(reason), do: "agent environment refused at boot (#{reason})"

  ## The Endpoint

  describe "the check VM's Endpoint" do
    test "with PORT unset, check mode resolves the inert 127.0.0.1:4130 tuple, no server", ctx do
      config = composed!(check_vm_env(ctx, %{}))
      http = http(config)

      assert {http[:ip], http[:port]} == {{127, 0, 0, 1}, 4130},
             "C2* S1 P0 (Codex b684dba9 M2): the default check VM resolves " <>
               "#{inspect(http)}; Launcher.check/1 requires 127.0.0.1:4130"

      assert Keyword.get(endpoint(config), :server) == false
    end

    test "control: an explicit PORT=4130 resolves 127.0.0.1:4130", ctx do
      http = http(composed!(check_vm_env(ctx, %{"PORT" => "4130"})))
      assert {http[:ip], http[:port]} == {{127, 0, 0, 1}, 4130}
    end

    test "control: without the selector the dev VM keeps its declared 127.0.0.1:4120", ctx do
      env = check_vm_env(ctx, %{"SDR_AGENT_ENV" => nil, "SDR_AGENT_ENV_STEP" => nil})
      config = composed!(env)
      http = http(config)

      assert {http[:ip], http[:port]} == {{127, 0, 0, 1}, 4120}
      refute Keyword.has_key?(sdr(config), AgentEnv)
    end
  end

  ## The other P0 items, as composed

  describe "the check VM's other P0 items" do
    test "control: the Repo target is forced and neutralized, the sinks and witness kept", ctx do
      config = composed!(check_vm_env(ctx, %{}))
      sdr = sdr(config)
      repo = Keyword.fetch!(sdr, SdrAgent.Repo)

      assert {repo[:database], repo[:hostname], repo[:port]} ==
               {"sdr_agent_agentenv", "localhost", 5520}

      for key <- [:url, :socket, :socket_dir, :endpoints] do
        assert Keyword.get(repo, key) == nil, inspect(key)
      end

      assert Keyword.fetch!(sdr, :otel_capture_content) == false
      assert Keyword.fetch!(sdr, :suppression_check) == SdrAgent.SDR.SuppressionCheck.Store

      assert Keyword.fetch!(sdr, :anchor_sinks) ==
               [{:file, FileSink, directory: Path.join(ctx.root, "anchors")}]

      assert get_in(sdr, [SdrAgent.Agents.Witness, :store_root]) ==
               Path.join(ctx.root, "evidence")

      agent_env = Keyword.fetch!(sdr, AgentEnv)
      assert {agent_env[:root], agent_env[:mode], agent_env[:step]} == {ctx.root, :check, :check}
    end

    test "control: with the composed check configuration, start and Repo still refuse", ctx do
      config = composed!(check_vm_env(ctx, %{}))
      Application.put_env(:sdr_agent, AgentEnv, Keyword.fetch!(sdr(config), AgentEnv))

      assert_raise RuntimeError, refused(:undeclared_step), fn -> Boot.check_start!() end

      assert_raise RuntimeError, refused(:undeclared_step), fn ->
        Boot.check_repo_start!(:supervisor)
      end
    end
  end

  ## The composition into the Launcher

  describe "the composed check configuration and Launcher.check/1" do
    test "the default (PORT unset) and explicit PORT=4130 check VMs pass run on a bound root",
         ctx do
      BootFx.agentenv_bound!(ctx.root, lease: :none)

      for overrides <- [%{}, %{"PORT" => "4130"}] do
        inputs = launcher_inputs(ctx, composed!(check_vm_env(ctx, overrides)))

        assert Code.ensure_loaded?(@launcher),
               "C2* S1 RED-3: #{inspect(@launcher)} is not available"

        assert function_exported?(@launcher, :check, 1),
               "C2* S1 RED-3: #{inspect(@launcher)}.check/1 is not exported"

        assert apply(@launcher, :check, [inputs]) == :ok, inspect(overrides)
      end
    end
  end
end

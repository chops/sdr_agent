defmodule SdrAgent.AI.ProviderRuntimeTest do
  @moduledoc """
  Q0.1 runtime provider selection (ADR-0004 runtime-selection amendment):
  `SDR_MODEL_PROVIDER` is read by `config/runtime.exs` — Fake by default,
  ClaudeCLI only in development, refused in test (hermetic) and prod
  (personal-local boundary) — and the selected ClaudeCLI runs as exactly
  one supervised, named server that callers are resolved to. A missing
  server is a typed error, never a raise or a silent fallback to Fake.
  """
  # Reads and sets the process environment and the application env.
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.Runtime

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @env ~w(SDR_MODEL_PROVIDER SDR_CLAUDE_CLI_TIMEOUT_MS DATABASE_URL SECRET_KEY_BASE
          TOKEN_SIGNING_SECRET)

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_provider = Application.fetch_env!(:sdr_agent, :model_provider)
    previous_cli = Application.fetch_env(:sdr_agent, ClaudeCLI)

    System.delete_env("SDR_MODEL_PROVIDER")
    System.delete_env("SDR_CLAUDE_CLI_TIMEOUT_MS")
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/sdr_config_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("test-only-key-", 8))
    System.put_env("TOKEN_SIGNING_SECRET", "test-only-token-secret")

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Application.put_env(:sdr_agent, :model_provider, previous_provider)

      case previous_cli do
        {:ok, value} -> Application.put_env(:sdr_agent, ClaudeCLI, value)
        :error -> Application.delete_env(:sdr_agent, ClaudeCLI)
      end
    end)

    :ok
  end

  defp selected(env) do
    base = Config.Reader.read!("config/config.exs", env: env, target: :host)
    runtime = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    config = Config.Reader.merge(base, runtime)[:sdr_agent]
    {config[:model_provider], config[ClaudeCLI]}
  end

  describe "SDR_MODEL_PROVIDER in config/runtime.exs" do
    test "unset or fake selects the deterministic Fake in every environment" do
      for env <- [:dev, :test, :prod], do: assert({Fake, nil} = selected(env))

      System.put_env("SDR_MODEL_PROVIDER", "fake")
      for env <- [:dev, :test, :prod], do: assert({Fake, nil} = selected(env))
    end

    test "claude_cli is allowed in development with a configured timeout" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
      assert {ClaudeCLI, [timeout: 240_000]} = selected(:dev)

      System.put_env("SDR_CLAUDE_CLI_TIMEOUT_MS", "90000")
      assert {ClaudeCLI, [timeout: 90_000]} = selected(:dev)
    end

    test "claude_cli refuses to boot in prod (ADR-0004 personal-local boundary)" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")

      assert_raise RuntimeError, ~r/SDR_MODEL_PROVIDER=claude_cli.*prod.*ADR-0004/s, fn ->
        selected(:prod)
      end
    end

    test "claude_cli refuses in test: tests stay hermetic" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")

      assert_raise RuntimeError, ~r/SDR_MODEL_PROVIDER=claude_cli.*test.*hermetic/s, fn ->
        selected(:test)
      end
    end

    test "unknown values and malformed timeouts are refused, never defaulted" do
      for value <- ["typo", "", "codex_app_server", "CLAUDE_CLI"] do
        System.put_env("SDR_MODEL_PROVIDER", value)

        for env <- [:dev, :test, :prod] do
          assert_raise RuntimeError, ~r/SDR_MODEL_PROVIDER must be fake or claude_cli/, fn ->
            selected(env)
          end
        end
      end

      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")

      for timeout <- ["0", "-5", "ten", "100ms", "", "999"] do
        System.put_env("SDR_CLAUDE_CLI_TIMEOUT_MS", timeout)

        assert_raise RuntimeError, ~r/SDR_CLAUDE_CLI_TIMEOUT_MS/, fn -> selected(:dev) end
      end
    end
  end

  describe "supervision" do
    test "the Fake starts no provider process" do
      Application.put_env(:sdr_agent, :model_provider, Fake)
      assert Runtime.children() == []
    end

    test "ClaudeCLI starts exactly one named server (concurrency 1) with the configured timeout" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 90_000)

      assert [{ClaudeCLI, opts}] = Runtime.children()
      assert opts[:name] == ClaudeCLI.server()
      assert opts[:timeout] == 90_000
    end

    test "the provider server starts before Oban, so no job can run before it exists" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      children = SdrAgent.Application.children()

      provider = Enum.find_index(children, &match?({ClaudeCLI, _}, &1))
      oban = Enum.find_index(children, &match?({Oban, _}, &1))
      assert provider && oban && provider < oban
      assert Enum.count(children, &match?({ClaudeCLI, _}, &1)) == 1
    end
  end

  describe "resolving a run's model options" do
    test "the Fake passes through unchanged (default and explicit)" do
      Application.put_env(:sdr_agent, :model_provider, Fake)
      assert {:ok, [provider: Fake]} = Runtime.resolve([])

      assert {:ok, [provider: Fake, provider_options: [responder: SdrAgent.SDR.FakeBrain]]} =
               Runtime.resolve(
                 provider: Fake,
                 provider_options: [responder: SdrAgent.SDR.FakeBrain]
               )
    end

    test "ClaudeCLI without its server is a typed error, for the default and a named provider" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      refute GenServer.whereis(ClaudeCLI.server())

      assert {:error, :provider_not_running} = Runtime.resolve([])

      Application.put_env(:sdr_agent, :model_provider, Fake)
      assert {:error, :provider_not_running} = Runtime.resolve(provider: ClaudeCLI)
    end

    test "ClaudeCLI is injected with the named server when it runs" do
      start_named!("ready")
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      assert {:ok, model} = Runtime.resolve([])
      assert model[:provider] == ClaudeCLI
      assert model[:provider_options][:server] == ClaudeCLI.server()

      assert {:ok, model} = Runtime.resolve(provider: ClaudeCLI, provider_options: [])
      assert model[:provider_options][:server] == ClaudeCLI.server()
    end
  end

  describe "status (Admin)" do
    test "the Fake reports its fixture model and no attestation" do
      Application.put_env(:sdr_agent, :model_provider, Fake)

      assert %{
               provider: Fake,
               model_id: "fake-qualifier",
               model_alias: nil,
               reviewed_version: nil,
               server: :not_applicable,
               attestation: %{status: :not_applicable}
             } = Runtime.status()
    end

    test "ClaudeCLI reports alias, resolved id, reviewed version, server and attestation" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      assert %{server: :not_running, attestation: %{status: :not_running}} = Runtime.status()

      start_named!("ready")

      assert %{
               provider: ClaudeCLI,
               model_alias: "opus",
               model_id: "claude-opus-5-5",
               reviewed_version: "2.1.291",
               server: :running,
               attestation: %{status: :pending}
             } = Runtime.status()
    end
  end

  defp start_named!(mode) do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: [@fake, mode]}
    )
  end
end

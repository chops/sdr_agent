defmodule SdrAgent.AI.ProviderRuntimeTest do
  @moduledoc """
  Q0.1 runtime provider selection (ADR-0004 runtime-selection amendment):
  `SDR_MODEL_PROVIDER` is read by `config/runtime.exs` — Fake by default,
  ClaudeCLI only in development, refused in test (hermetic) and prod
  (personal-local boundary) — and the selected ClaudeCLI runs as exactly
  one supervised, named server that callers are resolved to. A missing
  server is a typed error, never a raise or a silent fallback to Fake.

  R0-02 (ADR-0004 R0 amendment, item 1): with ClaudeCLI selected,
  `SDR_CLAUDE_CLI_BIN` must be exactly the reviewed pinned CLI of
  `nix/app-claude-cli.identity` (path and sha256); unset or anything else
  refuses boot, never falling back to `claude` on `PATH`. The app's server
  is started with it; a pin that is absent or has gone missing refuses
  calls before any reservation, and every ordinary real call is staged
  (`:real_model_staged`, zero launches) until R0-03, C9 and R0-07 land.
  """
  # Reads and sets the process environment and the application env.
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.PinnedCLI
  alias SdrAgent.Test.ResolveHarness
  alias SdrAgent.Test.StatusHarness

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @env ~w(SDR_MODEL_PROVIDER SDR_CLAUDE_CLI_TIMEOUT_MS SDR_CLAUDE_CLI_BIN DATABASE_URL
          SECRET_KEY_BASE TOKEN_SIGNING_SECRET)

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_provider = Application.fetch_env!(:sdr_agent, :model_provider)
    previous_cli = Application.fetch_env(:sdr_agent, ClaudeCLI)

    System.delete_env("SDR_MODEL_PROVIDER")
    System.delete_env("SDR_CLAUDE_CLI_TIMEOUT_MS")
    System.delete_env("SDR_CLAUDE_CLI_BIN")
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

  # The boot refusal message for SDR_CLAUDE_CLI_BIN=value (flunks if accepted).
  defp boot_refusal(value) do
    System.put_env("SDR_CLAUDE_CLI_BIN", value)

    try do
      selected(:dev)
      flunk("#{inspect(value)} was accepted")
    rescue
      error in RuntimeError -> Exception.message(error)
    end
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

    test "claude_cli is allowed in development with a configured timeout and pinned CLI" do
      bin = PinnedCLI.inject_identity!()
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
      System.put_env("SDR_CLAUDE_CLI_BIN", bin)
      assert {ClaudeCLI, [timeout: 240_000, executable: ^bin]} = selected(:dev)

      System.put_env("SDR_CLAUDE_CLI_TIMEOUT_MS", "90000")
      assert {ClaudeCLI, [timeout: 90_000, executable: ^bin]} = selected(:dev)
    end

    test "R0-02: claude_cli without SDR_CLAUDE_CLI_BIN refuses to boot (no PATH fallback)" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")

      assert_raise RuntimeError, ~r/SDR_CLAUDE_CLI_BIN.*pinned.*bin\/app-claude-cli-root/s, fn ->
        selected(:dev)
      end
    end

    test "R0-02: SDR_CLAUDE_CLI_BIN must be exactly the reviewed pinned artifact" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
      elixir = PinnedCLI.inject_identity!()

      for {value, reason} <- [
            {Path.join(Path.dirname(elixir), "elixirc"), "not_the_pinned_path"},
            {"", "not_a_path"},
            {"bin/claude-code", "not_absolute"},
            {"claude-code", "not_absolute"},
            {"/nix/store/../../bin/sh", "not_canonical"},
            {"/bin/sh", "not_in_nix_store"},
            {Path.expand("../../support/fake_claude_cli.exs", __DIR__), "not_in_nix_store"},
            {PinnedCLI.missing_store_path(), "missing"}
          ] do
        assert boot_refusal(value) =~ "SDR_CLAUDE_CLI_BIN refused (#{reason})", inspect(value)
      end
    end

    test "R0-02: the pinned path with other content (sha256) refuses boot" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
      elixir = PinnedCLI.inject_identity!(nil, sha256: String.duplicate("0", 64))

      assert boot_refusal(elixir) =~ "SDR_CLAUDE_CLI_BIN refused (hash_mismatch)"
    end

    test "R0-02: against the shipped identity record, the dev shell's Elixir refuses boot" do
      System.put_env("SDR_MODEL_PROVIDER", "claude_cli")
      Application.delete_env(:sdr_agent, ClaudeCLI.PinnedExecutable)

      assert boot_refusal(PinnedCLI.store_path!()) =~
               ~r/SDR_CLAUDE_CLI_BIN refused \((not_the_pinned_path|unsupported_platform)\)/
    end

    test "R0-02: SDR_CLAUDE_CLI_BIN is ignored unless claude_cli is selected" do
      System.put_env("SDR_CLAUDE_CLI_BIN", "relative/never-checked")
      for env <- [:dev, :test, :prod], do: assert({Fake, nil} = selected(env))

      System.put_env("SDR_MODEL_PROVIDER", "fake")
      for env <- [:dev, :test, :prod], do: assert({Fake, nil} = selected(env))
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
      System.put_env("SDR_CLAUDE_CLI_BIN", PinnedCLI.inject_identity!())

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

      # C2-02b2α: the profile tree, whose coordinator names the one server.
      assert [{ProfileSupervisor, tree}] = Runtime.children()
      opts = tree[:server].(:claude_cli_opus)
      assert opts[:timeout] == 90_000
      refute Keyword.has_key?(opts, :name), "the coordinator registers ClaudeCLI.server()"
    end

    test "R0-02: the app's server is started with the configured pinned CLI" do
      bin = PinnedCLI.store_path!()
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 90_000, executable: bin)

      assert [{ProfileSupervisor, tree}] = Runtime.children()
      assert tree[:server].(:claude_cli_opus)[:executable] == bin
    end

    test "R0-03: the app's server is started with the desired profile (default Opus)" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 90_000)

      # C2-02c test 13: with no coordinator, ClaudeCLI's desired profile is
      # unknown, never the registry default (the coordinator still boots at
      # the default only after a successful read finds no setting).
      assert Runtime.desired_profile() == {:error, :unknown}

      # The profile is not an environment knob: only the (C2) persisted
      # setting may choose another reviewed profile. The coordinator runs
      # the setting's profile, or desired_profile/0 before any setting.
      Application.put_env(:sdr_agent, ClaudeCLI, profile: :claude_cli_sonnet)
      assert [{ProfileSupervisor, tree}] = Runtime.children()
      refute Keyword.has_key?(tree[:server].(:claude_cli_opus), :profile)
    end

    test "the provider server starts before Oban, so no job can run before it exists" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      children = SdrAgent.Application.children()

      # C2-02b2α: the profile tree runs the one server.
      provider = Enum.find_index(children, &match?({ProfileSupervisor, _}, &1))
      oban = Enum.find_index(children, &match?({Oban, _}, &1))
      assert provider && oban && provider < oban
      assert Enum.count(children, &match?({ProfileSupervisor, _}, &1)) == 1
      refute Enum.any?(children, &match?({ClaudeCLI, _}, &1)), "no bare server child"
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

  describe "Q0.1 consult: health-checked resolution and the app's supervised child" do
    test "a blocked or launcher-less named server is refused, never downgraded" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      start_supervised!(
        {ClaudeCLI, name: ClaudeCLI.server(), command: nil, command_args: ["claude"]},
        id: :shimless
      )

      assert {:error, :llm_proxy_shim_not_found} = Runtime.resolve([])
      stop_supervised!(:shimless)
      # Its reaper releases the lease as its cleanup receipt.
      assert eventually(fn -> ClaudeCLI.Reaper.lease(ClaudeCLI.server()) == nil end)

      # A lease still held by a dead reaper (cleanup never confirmed).
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}
      :persistent_term.put({ClaudeCLI.Reaper, ClaudeCLI.server()}, {:held, dead})
      on_exit(fn -> ClaudeCLI.Reaper.release(ClaudeCLI.server()) end)

      start_named!("ready")
      assert {:error, :provider_not_quiescent} = Runtime.resolve([])
      assert {:error, :provider_not_quiescent} = Runtime.resolve(provider: ClaudeCLI)
    end

    test "R0-02: a configured pinned CLI that is missing is refused before any reservation" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      start_named!("ready", executable: PinnedCLI.missing_store_path())

      assert {:error, :pinned_cli_unavailable} = Runtime.resolve([])
      assert {:error, :pinned_cli_unavailable} = Runtime.resolve(provider: ClaudeCLI)
      assert Runtime.refusal_message(:pinned_cli_unavailable) =~ "no model call was made"

      # C2-02c 2b: a named server no coordinator binds is no status sample
      # (unavailable, never its own refusal). The pin refusal is status's
      # through the profile tree's consistent, released sample.
      assert %{effective: nil, refusal: :status_unavailable, observed_profile: :unknown} =
               Runtime.status()

      stop_supervised!(ClaudeCLI)
      assert eventually(fn -> ClaudeCLI.Reaper.lease(ClaudeCLI.server()) == nil end)
      tree!(executable: PinnedCLI.missing_store_path())

      assert {:error, :pinned_cli_unavailable} = Runtime.resolve([])

      assert %{
               effective: nil,
               refusal: :pinned_cli_unavailable,
               runtime_observation: :consistent,
               hold: :released,
               observed_profile: :claude_cli_opus
             } = Runtime.status()
    end

    test "R0-02: the real launcher without a pin is refused before any reservation" do
      dir = tmp_dir!()
      counter = PinnedCLI.stub_shim!(dir)
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      start_supervised!({ClaudeCLI, name: ClaudeCLI.server()})

      assert {:error, :pinned_cli_unavailable} = Runtime.resolve([])
      assert {:error, :pinned_cli_unavailable} = ClaudeCLI.complete(request(), [])
      assert PinnedCLI.launches(counter) == 0
    end

    # L2 E3 (deliberate change; was ":real_model_staged"): the reviewed pin
    # is now eligible; a request with no reserved row still launches nothing.
    test "E3: the real launcher with the reviewed pin is eligible; nothing launches unreserved" do
      dir = tmp_dir!()
      counter = PinnedCLI.stub_shim!(dir)
      bin = PinnedCLI.inject_identity!()
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, executable: bin)
      [child] = Runtime.children()
      ledger!()
      start_supervised!(child)
      await_released!()

      assert %{executable: ^bin, executable?: true, test_launcher?: false} =
               ClaudeCLI.attestation()

      resolved = Runtime.resolve([])

      assert match?({:ok, _model}, resolved),
             "E3: the reviewed pin resolves; got #{inspect(resolved)}"

      {:ok, model} = resolved
      assert model[:provider] == ClaudeCLI

      assert {:ok, _model} = Runtime.resolve(provider: ClaudeCLI)
      # Launch admission refuses the actorless request before any process;
      # with this tenant's ledger its denial is audited (Forbidden).
      assert {:error, :launch_not_admitted} = ClaudeCLI.complete(request(), [])
      assert %{effective: ClaudeCLI, refusal: nil} = Runtime.status()
      assert Runtime.refusal_message(:real_model_staged) =~ "no model call was made"
      assert PinnedCLI.launches(counter) == 0
    end

    test "R0-02: test_launcher is honoured only with an explicitly injected :command" do
      dir = tmp_dir!()
      counter = PinnedCLI.stub_shim!(dir)
      bin = PinnedCLI.inject_identity!()
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      start_supervised!(
        {ClaudeCLI, name: ClaudeCLI.server(), executable: bin, test_launcher: true}
      )

      # L2 E3 (deliberate change; was ":real_model_staged"): the ignored flag
      # leaves the real launcher, now eligible; unreserved, nothing launches.
      assert %{test_launcher?: false} = ClaudeCLI.attestation()
      resolved = Runtime.resolve([])

      assert match?({:ok, _model}, resolved),
             "E3: the real launcher resolves; got #{inspect(resolved)}"

      # No tenant exists here, so the actorless denial cannot be audited and
      # the server's rescue reports :launch_admission_failed; no process.
      assert {:error, :launch_admission_failed} = ClaudeCLI.complete(request(), [])
      assert PinnedCLI.launches(counter) == 0
    end

    test "status reports the configured and the effective provider and the model profile" do
      Application.put_env(:sdr_agent, :model_provider, Fake)
      assert %{configured: Fake, effective: Fake, profile_id: :fake} = Runtime.status()

      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      # C2-02c 2b: no coordinator is an unavailable status whose model
      # profile is unknown (nil), never the registry default.
      assert %{
               configured: ClaudeCLI,
               effective: nil,
               refusal: :status_unavailable,
               profile_id: nil,
               ledger_observation: :unavailable
             } = Runtime.status()

      tree!()

      assert %{
               configured: ClaudeCLI,
               effective: ClaudeCLI,
               refusal: nil,
               profile_id: :claude_cli_opus,
               effective_profile: :claude_cli_opus
             } =
               Runtime.status()

      # A coordinator that positively runs no server: not running, at the
      # confirmed desired (default) profile. (Last: it retries its boot.)
      StatusHarness.stop_tree!()
      no_server_tree!()

      assert %{
               configured: ClaudeCLI,
               effective: nil,
               refusal: :provider_not_running,
               profile_id: :claude_cli_opus
             } = Runtime.status()
    end

    test "the application's child restarts after a crash, admitting calls again" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 90_000)
      [child] = Runtime.children()
      ledger!()
      start_supervised!(child)
      # No pin and no shim here: the server runs, held (its preflight fails).
      assert eventually(fn -> ClaudeCLI.admission() != %{admission: :not_running} end)
      server = GenServer.whereis(ClaudeCLI.server())

      assert %{admission: :open} = ClaudeCLI.admission()
      Process.exit(server, :kill)

      assert eventually(fn ->
               case GenServer.whereis(ClaudeCLI.server()) do
                 pid when is_pid(pid) -> pid != server
                 _ -> false
               end
             end)

      assert eventually(fn -> ClaudeCLI.admission() == %{admission: :open} end)
      assert %{status: :pending} = ClaudeCLI.attestation()
    end
  end

  describe "status (Admin)" do
    test "the Fake reports its fixture model and no attestation" do
      Application.put_env(:sdr_agent, :model_provider, Fake)

      assert %{
               provider: Fake,
               profile_id: :fake,
               model_id: "fake-qualifier",
               model_alias: nil,
               reviewed_version: nil,
               server: :not_applicable,
               attestation: %{status: :not_applicable}
             } = Runtime.status()
    end

    test "ClaudeCLI reports alias, resolved id, reviewed version, server and attestation" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)

      # C2-02c 2b: with no coordinator the server and its attestation are
      # unknown, not positively absent.
      assert %{server: :unknown, attestation: %{status: :unknown}} = Runtime.status()

      tree!()

      assert %{
               provider: ClaudeCLI,
               profile_id: :claude_cli_opus,
               model_alias: "opus",
               model_id: "claude-opus-5-5",
               reviewed_version: "2.1.294",
               server: :running,
               attestation: %{status: :pending}
             } = Runtime.status()

      # Positively absent: the coordinator binds no server (every start
      # fails before the server's init returns). Last: it retries its boot.
      StatusHarness.stop_tree!()
      no_server_tree!()

      assert %{
               server: :not_running,
               attestation: %{status: :not_running},
               observed_profile: :none,
               profile_id: :claude_cli_opus,
               model_alias: "opus"
             } = Runtime.status()
    end

    test "R0-03: ClaudeCLI reports the running server's profile" do
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      # C2-02c: the profile is the coordinator-bound server's, so the tree
      # runs Sonnet after a completed switch (the setting's profile).
      tenant = tree!()
      ctx = %{admin: SdrAgent.AuditCase.human(:admin, tenant)}
      switch = ResolveHarness.request_switch!(ctx)
      ResolveHarness.await_switch!(ctx, switch.id, :completed)

      ResolveHarness.await_status!(
        &(&1.hold == :released and &1.profile_id == :claude_cli_sonnet),
        20_000
      )

      ResolveHarness.drain!()

      assert %{
               profile_id: :claude_cli_sonnet,
               observed_profile: :claude_cli_sonnet,
               model_alias: "sonnet",
               model_id: "claude-sonnet-5-5",
               reviewed_version: "2.1.294"
             } = Runtime.status()
    end

    test "R0-02: ClaudeCLI reports the pinned CLI path it launches (no CLI is run)" do
      bin = PinnedCLI.store_path!()
      Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
      Application.put_env(:sdr_agent, ClaudeCLI, executable: bin)

      assert %{cli_executable: ^bin} = Runtime.status()

      Application.put_env(:sdr_agent, ClaudeCLI, [])
      assert %{cli_executable: nil} = Runtime.status()

      Application.put_env(:sdr_agent, :model_provider, Fake)
      assert %{cli_executable: nil} = Runtime.status()
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  # C2-02b2α: the profile tree's coordinator allocates every start in the
  # ledger, so these cases run with a sandboxed database and a tenant.
  defp ledger! do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SdrAgent.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(SdrAgent.Repo, {:shared, self()})
    {:ok, _tenant} = SdrAgent.Audit.bootstrap(slug: "demo", name: "Demo Tenant")
  end

  # C2-02c: status is the coordinator's row plus its bound server's sample,
  # so status cases run the profile tree (the fake CLI under the test
  # launcher, ready; `server` adds ClaudeCLI options) with a sandboxed
  # ledger, released. Returns the tenant.
  defp tree!(server \\ []) do
    tenant = ledgered!()
    ResolveHarness.lease_cleanup!()
    StatusHarness.tree!(server: server)
    ResolveHarness.await_status!(&(&1.hold == :released))
    ResolveHarness.drain!()
    tenant
  end

  # The profile tree whose every start fails before the server's init
  # returns: the coordinator positively binds no server.
  defp no_server_tree! do
    ledgered!()
    ResolveHarness.lease_cleanup!()
    StatusHarness.tree!(server: [timeout: 1])

    assert eventually(fn ->
             match?(
               %{observed_profile: :none, desired_profile: %{profile_id: _}},
               Runtime.status()
             )
           end)
  end

  defp ledgered! do
    case Process.get({__MODULE__, :tenant}) do
      nil ->
        {:ok, tenant} = ledger!()
        Process.put({__MODULE__, :tenant}, tenant)
        tenant

      tenant ->
        tenant
    end
  end

  defp await_released! do
    assert eventually(fn ->
             match?(%{hold: :released}, SdrAgent.AI.ModelProvider.Coordinator.status())
           end)
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "sdr-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp request do
    %{
      id: "runtime-staged",
      operation: "model.complete",
      prompt: "qualify",
      schema: Zoi.object(%{answer: Zoi.string()}),
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
      }
    }
  end

  defp start_named!(mode, opts \\ []) do
    start_supervised!(
      {ClaudeCLI,
       Keyword.merge(
         [
           name: ClaudeCLI.server(),
           command: System.find_executable("elixir"),
           test_launcher: true,
           command_args: [@fake, mode]
         ],
         opts
       )}
    )
  end
end

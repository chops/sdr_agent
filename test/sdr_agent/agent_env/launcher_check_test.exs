defmodule SdrAgent.AgentEnv.LauncherCheckTest do
  @moduledoc """
  C2* S1 PR-B RED-3: the pre-lease readiness check P0,
  `SdrAgent.AgentEnv.Launcher.check/1` (plan
  `claude-c2star-s1-environment-plan-r2.md` sections 5.4 and 6.1 row P0;
  AC2, AC6; ADR-0004 agent-environment amendment item 2; T-V1, Elixir half).

  `check(inputs)` is a function of one inputs map, so the Mix task gathers
  the real values and the tests give synthetic ones:

      %{
        intent: :provision | :run,
        env: %{"SDR_MODEL_PROVIDER" => ...},       # the OS environment
        root: root,                                # the private root
        build_path: path, deps_path: path,         # Mix's real paths
        config: %{
          repo: keyword,                           # the resolved Repo config
          endpoint_http: keyword,                  # the resolved Endpoint :http
          anchor_sinks: list,                      # config :sdr_agent, :anchor_sinks
          witness_store_root: path | nil,
          suppression_check: module,
          otel_capture_content: boolean
        },
        connect: (ip, port -> {:ok, term} | {:error, atom})   # the port probe
      }

  Malformed inputs (not a map, a missing or ill-typed key, an unknown
  intent, a sink that is not `{atom, module, keyword}` or an improper list,
  a path with a NUL byte; Codex `43a40f9b` M1) are `{:error, :invalid_inputs}` and an unsupported
  `SDR_MODEL_PROVIDER` (other than unset, `fake` or `claude_cli`) is
  `{:error, :provider_refused}`, before any item and with no probe (Codex
  `b684dba9` Q1). Otherwise it returns `:ok` or `{:error, reason}` for the
  first failing item, in this order (Q1's accepted precedence):

    * `:repo_target_refused` — the Repo is not exactly `sdr_agent_agentenv`
      on `localhost`/`127.0.0.1`:5520 with `url`, `socket`, `socket_dir` and
      `endpoints` absent or nil (so `sdr_agent_dev` and every
      `sdr_agent_test*` name are refused);
    * `:port_refused` — HTTP is not `127.0.0.1:4130`;
    * `:port_in_use` / `:port_probe_failed` — `connect.({127, 0, 0, 1},
      4130)` answers `{:ok, _}` (listening) or an error other than
      `:econnrefused` (free);
    * `:root_refused` — the root or one of `build`, `deps`, `state`,
      `evidence`, `anchors`, `tmp` is not a physical (never symlinked) 0700
      directory;
    * `:build_paths_refused` — Mix's build or deps path is not physically
      under the root (a symlink component or `..` escaping it is refused,
      not just a lexical prefix), or lies in a `.devenv` directory;
    * `:witness_root_missing`, `:anchor_sinks_refused` (exactly one file
      sink, physically under `<root>/anchors`), `:suppression_check_not_store`,
      `:otel_capture_refused`;
    * the classification (`State.classify(root, :unknown)`):
      `:lease_held`, `:quarantined`, `:not_fresh` (provision needs fresh),
      `:environment_unbound` (run needs bound);
    * `:agent_env_not_spend_ready` — only when `SDR_MODEL_PROVIDER` is
      `claude_cli`: `SpendReady.preflight/1` (S1: always refuses).

  It takes no lease, writes no file, opens no Repo and reads no database.
  A lease never masks an unknown file (`:quarantined`, Q2), and an absent
  `state/` refuses readiness (`:root_refused`) although it classifies fresh
  (Q8). Input shape (`:invalid_inputs`) comes first and an unsupported
  provider (`:provider_refused`) next, both before any item or probe; a
  symlink component is refused even when it resolves inside the root; and
  no refusal logs or returns anything of the inputs (Codex `31b72fea`).

  The production probe `probe/2` (`connect:` of the real Mix caller) is one
  `:gen_tcp.connect/4` to `{127, 0, 0, 1}` with a finite timeout; it closes
  any socket it opened before returning `{:ok, :listening}`, and passes any
  error through, so only `:econnrefused` reads as free. Its test uses a
  loopback listener on an ephemeral port it opens itself, never 4130.

  RED: `SdrAgent.AgentEnv.Launcher` does not exist (structural, guarded
  after the fixtures). The "fixtures" controls use existing APIs only and
  execute now (Q10).

  Hermetic: physical roots under `tmp/agent-env-roots`, an injected port
  probe; no port, database, real Mix or CLI.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @launcher SdrAgent.AgentEnv.Launcher
  @spend_ready SdrAgent.AgentEnv.SpendReady
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]
  @steps [:create, :migrate, :seed, :probe]

  setup do
    %{home: home, root: root} = BootFx.home!()

    for dir <- @subdirectories do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    probes = start_supervised!(%{id: :probes, start: {Agent, :start_link, [fn -> [] end]}})
    %{home: home, root: root, probes: probes}
  end

  ## Helpers

  defp check(inputs) do
    assert Code.ensure_loaded?(@launcher), "C2* S1 RED-3: #{inspect(@launcher)} is not available"

    assert function_exported?(@launcher, :check, 1),
           "C2* S1 RED-3: #{inspect(@launcher)}.check/1 is not exported"

    apply(@launcher, :check, [inputs])
  end

  defp require_probe! do
    assert Code.ensure_loaded?(@launcher), "C2* S1 RED-3: #{inspect(@launcher)} is not available"

    assert function_exported?(@launcher, :probe, 2),
           "C2* S1 RED-3: #{inspect(@launcher)}.probe/2 is not exported"
  end

  # Runs `fun` in this process and returns `{result, args}`: the argument
  # lists of every :gen_tcp.connect/4 call this process made meanwhile.
  defp trace_connects(fun) do
    collector = spawn(fn -> collect_connects([]) end)
    session = :trace.session_create(:c2star_s1_probe_connects, collector, [])

    try do
      _ = :trace.function(session, {:gen_tcp, :connect, 4}, true, [])
      _ = :trace.process(session, self(), true, [:call])
      result = fun.()
      _ = :trace.process(session, self(), false, [:call])
      ref = :trace.delivered(session, self())

      receive do
        {:trace_delivered, _tracee, ^ref} -> :ok
      after
        5_000 -> flunk("C2* S1: trace delivery was not confirmed")
      end

      send(collector, {:connects, self()})

      receive do
        {:connects, args} -> {result, args}
      after
        5_000 -> flunk("C2* S1: the connect collector did not answer")
      end
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_connects(acc) do
    receive do
      {:trace, _pid, :call, {:gen_tcp, :connect, args}} -> collect_connects([args | acc])
      {:connects, from} -> send(from, {:connects, Enum.reverse(acc)})
    end
  end

  defp free(ctx) do
    probes = ctx.probes

    fn ip, port ->
      Agent.update(probes, &[{ip, port} | &1])
      {:error, :econnrefused}
    end
  end

  defp inputs(ctx, intent, overrides \\ %{}) do
    base = %{
      intent: intent,
      env: %{},
      root: ctx.root,
      build_path: Path.join([ctx.root, "build", "dev"]),
      deps_path: Path.join(ctx.root, "deps"),
      config: %{
        repo: [database: "sdr_agent_agentenv", hostname: "localhost", port: 5520],
        endpoint_http: [ip: {127, 0, 0, 1}, port: 4130],
        anchor_sinks: [{:file, FileSink, directory: Path.join(ctx.root, "anchors")}],
        witness_store_root: Path.join(ctx.root, "evidence"),
        suppression_check: SdrAgent.SDR.SuppressionCheck.Store,
        otel_capture_content: false
      },
      connect: free(ctx)
    }

    File.mkdir_p!(base.build_path)
    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      :config, l, r -> Map.merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp config(ctx, intent, key, value), do: inputs(ctx, intent, %{config: %{key => value}})

  defp bound!(ctx), do: BootFx.agentenv_bound!(ctx.root, lease: :none)

  defp state_digests(root) do
    Map.new(BootFx.state_files(root), &{&1, BootFx.file_sha256!(Path.join([root, "state", &1]))})
  end

  ## Fixture controls (Codex b684dba9 Q10): unguarded, existing APIs only

  describe "fixtures" do
    test "the synthetic root, inputs and probe recorder operate without the Launcher", ctx do
      bound = bound!(ctx)

      for dir <- [ctx.root | Enum.map(@subdirectories, &Path.join(ctx.root, &1))] do
        assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(dir)
        assert Bitwise.band(mode, 0o777) == 0o700, dir
      end

      inputs = inputs(ctx, :run)
      assert File.dir?(inputs.build_path)
      assert String.starts_with?(inputs.build_path, ctx.root <> "/")
      assert Agent.get(ctx.probes, & &1) == []
      assert inputs.connect.({127, 0, 0, 1}, 4130) == {:error, :econnrefused}
      assert Agent.get(ctx.probes, & &1) == [{{127, 0, 0, 1}, 4130}]
      assert Code.ensure_loaded?(FileSink)
      assert Code.ensure_loaded?(inputs.config.suppression_check)

      assert {:valid, binding, _data} = State.read(ctx.root, :environment)
      assert binding == bound.binding_sha256

      receipts = Enum.map(@steps, &{:receipt, bound.bootstrap_nonce, &1})

      for name <- [:pending, :created | receipts] do
        assert match?({:valid, _sha256, _data}, State.read(ctx.root, name)), inspect(name)
      end

      refute File.exists?(Fx.path(ctx.root, :lease))
    end
  end

  ## Controls

  describe "controls" do
    test "nil url, socket, socket_dir and endpoints (as the forced config) are the target", ctx do
      bound!(ctx)

      repo = [
        database: "sdr_agent_agentenv",
        hostname: "localhost",
        port: 5520,
        url: nil,
        socket: nil,
        socket_dir: nil,
        endpoints: nil
      ]

      assert check(config(ctx, :run, :repo, repo)) == :ok
    end

    test "run on a bound root passes with the Fake, probing exactly 127.0.0.1:4130 once", ctx do
      bound!(ctx)
      before = state_digests(ctx.root)

      {result, calls} = BootFx.trace_calls(@spend_ready, fn -> check(inputs(ctx, :run)) end)

      assert result == :ok
      assert Agent.get(ctx.probes, & &1) == [{{127, 0, 0, 1}, 4130}]
      assert calls == [], "C2* S1 P0: SpendReady.preflight/1 runs only for claude_cli"
      assert state_digests(ctx.root) == before, "C2* S1 P0: the check writes nothing"
    end

    test "provision on a fresh root passes", ctx do
      assert check(inputs(ctx, :provision)) == :ok
      assert BootFx.state_files(ctx.root) == []
    end

    test "127.0.0.1 is the same loopback Repo target", ctx do
      bound!(ctx)

      repo = [database: "sdr_agent_agentenv", hostname: "127.0.0.1", port: 5520]
      assert check(config(ctx, :run, :repo, repo)) == :ok
    end
  end

  ## Each item

  describe "the Repo target" do
    test "any other database, host, port or connection override is refused", ctx do
      bound!(ctx)
      fixed = [database: "sdr_agent_agentenv", hostname: "localhost", port: 5520]

      for repo <- [
            Keyword.put(fixed, :database, "sdr_agent_dev"),
            Keyword.put(fixed, :database, "sdr_agent_test"),
            Keyword.put(fixed, :database, "sdr_agent_test_c4"),
            Keyword.put(fixed, :database, "sdr_agent_agentenv2"),
            Keyword.put(fixed, :hostname, "db.example.invalid"),
            Keyword.put(fixed, :port, 5432),
            Keyword.put(fixed, :url, "ecto://synthetic:synthetic@elsewhere.invalid/other"),
            Keyword.put(fixed, :socket_dir, "/nonexistent"),
            Keyword.put(fixed, :socket, "/nonexistent/.s.PGSQL.5520"),
            Keyword.put(fixed, :endpoints, [{"elsewhere.invalid", 5520}]),
            Keyword.put(fixed, :endpoints, [{"localhost", 5520}])
          ] do
        assert check(config(ctx, :run, :repo, repo)) == {:error, :repo_target_refused},
               inspect(repo)
      end
    end
  end

  describe "the port" do
    test "HTTP other than 127.0.0.1:4130 is refused", ctx do
      bound!(ctx)

      for http <- [
            [ip: {127, 0, 0, 1}, port: 4120],
            [ip: {127, 0, 0, 1}, port: 4122],
            [ip: {0, 0, 0, 0}, port: 4130],
            [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4130]
          ] do
        assert check(config(ctx, :run, :endpoint_http, http)) == {:error, :port_refused},
               inspect(http)
      end
    end

    test "the port is probed only after the Repo target and the HTTP tuple pass", ctx do
      bound!(ctx)
      other_repo = [database: "sdr_agent_dev", hostname: "localhost", port: 5520]

      assert check(config(ctx, :run, :repo, other_repo)) == {:error, :repo_target_refused}

      assert check(config(ctx, :run, :endpoint_http, ip: {127, 0, 0, 1}, port: 4120)) ==
               {:error, :port_refused}

      assert Agent.get(ctx.probes, & &1) == []

      assert check(inputs(ctx, :run)) == :ok
      assert Agent.get(ctx.probes, & &1) == [{{127, 0, 0, 1}, 4130}]
    end

    test "a listening 4130 is refused, and an unclear probe is refused", ctx do
      bound!(ctx)

      listening = fn _ip, _port -> {:ok, :socket} end
      assert check(inputs(ctx, :run, %{connect: listening})) == {:error, :port_in_use}

      for reason <- [:timeout, :ehostunreach, :eacces] do
        unclear = fn _ip, _port -> {:error, reason} end

        assert check(inputs(ctx, :run, %{connect: unclear})) == {:error, :port_probe_failed},
               inspect(reason)
      end
    end
  end

  describe "the private root" do
    test "a group- or world-accessible root or subdirectory is refused", ctx do
      bound!(ctx)

      for dir <- [ctx.root | Enum.map(@subdirectories, &Path.join(ctx.root, &1))] do
        File.chmod!(dir, 0o750)
        assert check(inputs(ctx, :run)) == {:error, :root_refused}, dir
        File.chmod!(dir, 0o700)
      end

      assert check(inputs(ctx, :run)) == :ok
    end

    test "a missing or symlinked subdirectory, or a symlinked root, is refused", ctx do
      bound!(ctx)
      tmp = Path.join(ctx.root, "tmp")
      File.rm_rf!(tmp)
      assert check(inputs(ctx, :run)) == {:error, :root_refused}

      elsewhere = Fx.root!("elsewhere")
      :ok = File.ln_s(elsewhere, tmp)
      assert check(inputs(ctx, :run)) == {:error, :root_refused}

      File.rm!(tmp)
      File.mkdir_p!(tmp)
      File.chmod!(tmp, 0o700)
      assert check(inputs(ctx, :run)) == :ok

      link = Path.join(ctx.home, "root-link")
      :ok = File.ln_s(ctx.root, link)
      assert check(inputs(ctx, :run, %{root: link})) == {:error, :root_refused}
    end

    test "an absent state directory refuses readiness, though it classifies fresh", ctx do
      state_dir = Path.join(ctx.root, "state")
      File.rmdir!(state_dir)

      assert check(inputs(ctx, :provision)) == {:error, :root_refused}
      refute File.exists?(state_dir)
    end
  end

  describe "the build paths" do
    test "build or deps paths outside the root, or in a .devenv directory, are refused", ctx do
      bound!(ctx)
      outside = Fx.root!("outside")
      devenv = Path.join([ctx.root, "build", ".devenv", "state"])
      File.mkdir_p!(devenv)

      for overrides <- [
            %{build_path: Path.join(outside, "build")},
            %{deps_path: Path.join(outside, "deps")},
            %{build_path: Path.expand(".devenv/state/build")},
            %{build_path: devenv}
          ] do
        assert check(inputs(ctx, :run, overrides)) == {:error, :build_paths_refused},
               inspect(overrides)
      end
    end

    test "a symlink component is refused even when it resolves inside the root", ctx do
      bound!(ctx)

      for {dir, overrides_for} <- [
            {"build", &%{build_path: Path.join(&1, "dev")}},
            {"deps", &%{deps_path: &1}},
            {"anchors", &%{config: %{anchor_sinks: [{:file, FileSink, directory: &1}]}}}
          ] do
        real = Path.join([ctx.root, dir, "real"])
        File.mkdir_p!(Path.join(real, "dev"))
        alias_link = Path.join([ctx.root, dir, "alias"])
        :ok = File.ln_s(real, alias_link)
        overrides = overrides_for.(alias_link)

        expected =
          if dir == "anchors",
            do: {:error, :anchor_sinks_refused},
            else: {:error, :build_paths_refused}

        assert check(inputs(ctx, :run, overrides)) == expected, inspect(overrides)
      end
    end

    test "a symlink component or .. escaping the root is refused, not just a prefix", ctx do
      bound!(ctx)
      outside = Fx.root!("escape")
      File.mkdir_p!(Path.join(outside, "dev"))
      build_link = Path.join([ctx.root, "build", "escape"])
      deps_link = Path.join([ctx.root, "deps", "escape"])
      :ok = File.ln_s(outside, build_link)
      :ok = File.ln_s(outside, deps_link)
      sibling = Path.join(Path.dirname(ctx.root), "escape-build")
      File.mkdir_p!(sibling)

      for overrides <- [
            %{build_path: Path.join(build_link, "dev")},
            %{deps_path: deps_link},
            %{build_path: Path.join([ctx.root, "build", "..", "..", "escape-build"])}
          ] do
        assert check(inputs(ctx, :run, overrides)) == {:error, :build_paths_refused},
               inspect(overrides)
      end
    end
  end

  describe "runtime configuration" do
    test "a missing witness root is refused", ctx do
      bound!(ctx)

      assert check(config(ctx, :run, :witness_store_root, nil)) ==
               {:error, :witness_root_missing}
    end

    test "anchor sinks other than one file sink under <root>/anchors are refused", ctx do
      bound!(ctx)
      outside = Fx.root!("anchors-outside")
      escape = Path.join([ctx.root, "anchors", "escape"])
      :ok = File.ln_s(outside, escape)

      for sinks <- [
            [{:file, FileSink, directory: escape}],
            [{:file, FileSink, directory: Path.join([ctx.root, "anchors", "..", "state"])}],
            [],
            [{:git, SdrAgent.Audit.AnchorSinks.GitSink, repository: "synthetic"}],
            [{:file, FileSink, directory: outside}],
            [{:file, FileSink, directory: Path.join(ctx.root, "state")}],
            [
              {:file, FileSink, directory: Path.join(ctx.root, "anchors")},
              {:ots, SdrAgent.Audit.AnchorSinks.OpenTimestampsSink, []}
            ]
          ] do
        assert check(config(ctx, :run, :anchor_sinks, sinks)) == {:error, :anchor_sinks_refused},
               inspect(sinks)
      end
    end

    test "a suppression check other than the Store is refused", ctx do
      bound!(ctx)
      no_store = SdrAgent.SDR.SuppressionCheck.NoStore

      assert check(config(ctx, :run, :suppression_check, no_store)) ==
               {:error, :suppression_check_not_store}
    end

    test "OTel content capture on is refused", ctx do
      bound!(ctx)

      assert check(config(ctx, :run, :otel_capture_content, true)) ==
               {:error, :otel_capture_refused}
    end
  end

  describe "classification" do
    test "provision needs a fresh root and run a bound one", ctx do
      assert check(inputs(ctx, :run)) == {:error, :environment_unbound}

      bound!(ctx)
      assert check(inputs(ctx, :provision)) == {:error, :not_fresh}
    end

    test "a held lease or a quarantined state refuses both intents", ctx do
      bound = BootFx.agentenv_bound!(ctx.root, lease: :run)
      assert is_binary(bound.nonce)

      for intent <- [:provision, :run] do
        assert check(inputs(ctx, intent)) == {:error, :lease_held}, inspect(intent)
      end

      File.rm!(Fx.path(ctx.root, :lease))
      File.write!(Path.join([ctx.root, "state", "unknown.file"]), "x")

      for intent <- [:provision, :run] do
        assert check(inputs(ctx, intent)) == {:error, :quarantined}, inspect(intent)
      end
    end

    test "a lease does not mask an unknown file: both intents see the quarantine", ctx do
      BootFx.agentenv_bound!(ctx.root, lease: :run)
      File.write!(Path.join([ctx.root, "state", "unknown.file"]), "x")

      for intent <- [:provision, :run] do
        assert check(inputs(ctx, intent)) == {:error, :quarantined}, inspect(intent)
      end
    end
  end

  ## Input validation and precedence (Codex b684dba9 Q1)

  describe "inputs" do
    test "malformed inputs are refused before any item, with no probe", ctx do
      bound!(ctx)
      valid = inputs(ctx, :run)

      for malformed <- [
            :not_a_map,
            [],
            Map.delete(valid, :connect),
            Map.delete(valid, :config),
            %{valid | intent: :bootstrap},
            %{valid | intent: "run"},
            %{valid | env: nil},
            %{valid | root: nil},
            %{valid | connect: fn -> :ok end},
            %{valid | config: Map.delete(valid.config, :repo)}
          ] do
        assert check(malformed) == {:error, :invalid_inputs}, inspect(malformed)
      end

      assert Agent.get(ctx.probes, & &1) == []
    end

    test "position: input shape first, then the provider, both before any item or probe", ctx do
      bound!(ctx)

      repo_fault = %{
        config: %{repo: [database: "sdr_agent_dev", hostname: "localhost", port: 5520]}
      }

      bogus = %{env: %{"SDR_MODEL_PROVIDER" => "bogus"}}
      listening = %{connect: fn _ip, _port -> {:ok, :socket} end}
      every = repo_fault |> deep_merge(bogus) |> deep_merge(listening)

      assert check(inputs(ctx, :bootstrap, every)) == {:error, :invalid_inputs}
      assert check(inputs(ctx, :run, every)) == {:error, :provider_refused}

      assert check(inputs(ctx, :run, deep_merge(repo_fault, listening))) ==
               {:error, :repo_target_refused}

      assert Agent.get(ctx.probes, & &1) == []
    end

    test "malformed nested sink options are invalid inputs: no probe, no echo", ctx do
      bound!(ctx)
      sentinel = "c2star-s1-sentinel-#{System.unique_integer([:positive])}"
      Logger.put_process_level(self(), :debug)

      malformed = [
        [{:file, FileSink, [{:directory, sentinel, :extra}]}],
        [{:file, FileSink, [{:directory, sentinel} | :improper]}],
        [{:file, FileSink, %{directory: sentinel}}],
        [{:file, FileSink}],
        [sentinel],
        [{:file, FileSink, [directory: Path.join(ctx.root, "anchors")]} | :improper],
        [{:file, FileSink, [directory: Path.join(ctx.root, "anchors") <> <<0>> <> sentinel]}]
      ]

      log =
        capture_log([level: :debug], fn ->
          for {sinks, index} <- Enum.with_index(malformed) do
            assert check(config(ctx, :run, :anchor_sinks, sinks)) == {:error, :invalid_inputs},
                   "C2* S1 P0 (Codex 43a40f9b M1): malformed sinks case #{index}"
          end
        end)

      Logger.delete_process_level(self())
      assert Agent.get(ctx.probes, & &1) == [], "C2* S1 P0: the probe ran on malformed input"
      refute log =~ sentinel
    end

    test "an unsupported provider value is refused; fake is accepted", ctx do
      bound!(ctx)

      for provider <- ["bogus", "", "Fake", "claude-cli"] do
        assert check(inputs(ctx, :run, %{env: %{"SDR_MODEL_PROVIDER" => provider}})) ==
                 {:error, :provider_refused},
               inspect(provider)
      end

      assert Agent.get(ctx.probes, & &1) == []
      assert check(inputs(ctx, :run, %{env: %{"SDR_MODEL_PROVIDER" => "fake"}})) == :ok
    end

    test "the first failing item is reported, in the accepted order", ctx do
      outside = Fx.root!("precedence-outside")
      tmp = Path.join(ctx.root, "tmp")
      no_store = SdrAgent.SDR.SuppressionCheck.NoStore

      faults = [
        repo_target_refused: %{
          config: %{repo: [database: "sdr_agent_dev", hostname: "localhost", port: 5520]}
        },
        port_refused: %{config: %{endpoint_http: [ip: {127, 0, 0, 1}, port: 4120]}},
        port_in_use: %{connect: fn _ip, _port -> {:ok, :socket} end},
        root_refused: :tmp_mode,
        build_paths_refused: %{build_path: Path.join(outside, "build")},
        witness_root_missing: %{config: %{witness_store_root: nil}},
        anchor_sinks_refused: %{config: %{anchor_sinks: []}},
        suppression_check_not_store: %{config: %{suppression_check: no_store}},
        otel_capture_refused: %{config: %{otel_capture_content: true}}
      ]

      claude_cli = %{env: %{"SDR_MODEL_PROVIDER" => "claude_cli"}}
      File.chmod!(tmp, 0o750)

      Enum.reduce(faults, faults, fn {reason, _fault}, remaining ->
        overrides =
          remaining
          |> Keyword.values()
          |> Enum.reject(&(&1 == :tmp_mode))
          |> Enum.reduce(claude_cli, &deep_merge(&2, &1))

        assert check(inputs(ctx, :run, overrides)) == {:error, reason}, inspect(reason)
        if reason == :root_refused, do: File.chmod!(tmp, 0o700)
        tl(remaining)
      end)

      assert check(inputs(ctx, :run, claude_cli)) == {:error, :environment_unbound}

      bound!(ctx)
      Fx.authorized!(ctx.root)
      assert check(inputs(ctx, :run, claude_cli)) == {:error, :agent_env_not_spend_ready}
      assert check(inputs(ctx, :run)) == :ok
    end
  end

  ## The production probe and diagnostics (Codex 31b72fea, owed before GREEN)

  describe "the production probe" do
    # Loopback only, on an ephemeral port this test opens itself (never 4130).
    test "probe/2: a listener is in use and its socket closed; a free port is refused" do
      require_probe!()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      {result, connects} =
        trace_connects(fn -> apply(@launcher, :probe, [{127, 0, 0, 1}, port]) end)

      assert match?({:ok, _}, result)
      assert [[{127, 0, 0, 1}, ^port, _options, timeout]] = connects
      assert is_integer(timeout) and timeout > 0 and timeout <= 5_000

      {:ok, accepted} = :gen_tcp.accept(listen, 1_000)
      assert :gen_tcp.recv(accepted, 0, 1_000) == {:error, :closed}
      :ok = :gen_tcp.close(accepted)
      :ok = :gen_tcp.close(listen)

      assert apply(@launcher, :probe, [{127, 0, 0, 1}, port]) == {:error, :econnrefused}
    end
  end

  describe "diagnostics" do
    test "refusals log and return nothing of the inputs", ctx do
      bound!(ctx)
      sentinel = "c2star-s1-sentinel-#{System.unique_integer([:positive])}"
      Logger.put_process_level(self(), :debug)

      cases = [
        %{intent: :run, sentinel: sentinel},
        inputs(ctx, :run, %{env: %{"SDR_MODEL_PROVIDER" => sentinel}}),
        config(ctx, :run, :repo, url: "ecto://user:#{sentinel}@elsewhere.invalid/db"),
        inputs(ctx, :run, %{build_path: Path.join(Fx.root!("diagnostics"), sentinel)})
      ]

      log =
        capture_log([level: :debug], fn ->
          for inputs <- cases do
            assert {:error, reason} = check(inputs)
            assert is_atom(reason)
            refute inspect(reason) =~ sentinel
          end
        end)

      Logger.delete_process_level(self())
      refute log =~ sentinel
    end
  end

  describe "claude_cli (AC6)" do
    test "claude_cli is refused pre-lease by SpendReady.preflight/1 (S1 fail-closed)", ctx do
      bound!(ctx)
      Fx.authorized!(ctx.root)

      {result, calls} =
        BootFx.trace_calls(@spend_ready, fn ->
          check(inputs(ctx, :run, %{env: %{"SDR_MODEL_PROVIDER" => "claude_cli"}}))
        end)

      assert result == {:error, :agent_env_not_spend_ready}
      assert {@spend_ready, :preflight, 1} in calls
      refute File.exists?(Fx.path(ctx.root, :lease))
    end
  end
end

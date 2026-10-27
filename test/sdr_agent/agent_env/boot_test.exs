defmodule SdrAgent.AgentEnv.BootTest do
  @moduledoc """
  C2* S1 PR-B RED-2: the leased configuration phase P2,
  `SdrAgent.AgentEnv.Boot.runtime_config!/2`, and its wiring in
  `config/runtime.exs` (plan `claude-c2star-s1-environment-plan-r2.md`
  sections 4.4, 6.1 row P2 and 6.2 L1, T-V5, T-V8 cases 1-2, T-V9 (boot),
  T-V4 (nonce), R6; the P5 correction `claude-c2star-s1-prb-p5-correction-r1.md`
  section 2 item 1, P5-2(b) at P2).

  `runtime_config!(config_env, env)` takes the OS environment as a map and
  returns `[{app, keyword}]`, which `config/runtime.exs` applies with
  `config/2`. It reads files only, never the database:

    * **Inert:** with none of `SDR_AGENT_ENV`, `SDR_AGENT_ENV_STEP` and
      `SDR_AGENT_ENV_NONCE` set it returns `[]` in every environment.
    * **Selector:** `agentenv-1` only, in `:dev` only. The root is
      `<HOME>/.local/state/sdr-agent/agent-env/agentenv-1` (ADR-0004
      agent-environment amendment, item 1), so these tests pass a fake
      `HOME`.
    * **Forced in every mode:** the Repo target `sdr_agent_agentenv` @
      `localhost:5520` (with `url`, `socket`, `socket_dir` and `endpoints`
      cleared, so no connection override can take precedence), OTel content
      capture off, and the `SdrAgent.AgentEnv` configuration (`root`, `mode`,
      `step`, `nonce`, and `database: "sdr_agent_agentenv"`, which PR-A's
      operation snapshot reads; Codex c9a6f6c7 R4). Anchor containment is
      physical (a symlink out of `<root>/anchors` is refused).
      Non-run modes also force the Fake provider and `server: false`; run
      mode forces HTTP `127.0.0.1:4130`.
    * **Refusal:** a `RuntimeError` whose whole message is
      `"agent environment refused at boot (<reason>)"`, with no path or
      value.

  Every refusal row changes one input of an accepted control, except the
  lease-mode rows: a lease's mode is checked before the nonce, the target
  and the bootstrap step order. These tests check out no sandbox
  connection, so a database read by P2 would fail them.

  RED: `SdrAgent.AgentEnv.Boot` does not exist (structural, guarded after
  the fixtures) and `config/runtime.exs` ignores the selector (the wiring
  rows; behavioural). The unset-selector wiring row is a control.

  Hermetic: physical roots under `tmp/agent-env-roots`, no database, port,
  process, real Mix or CLI.
  """
  # Sets the OS environment (wiring rows).
  use ExUnit.Case, async: false

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @boot SdrAgent.AgentEnv.Boot
  @fake SdrAgent.AI.ModelProvider.Fake
  @selector_vars ~w(SDR_AGENT_ENV SDR_AGENT_ENV_STEP SDR_AGENT_ENV_NONCE)

  setup do
    BootFx.home!()
  end

  ## Helpers

  defp require_boot! do
    assert Code.ensure_loaded?(@boot), "C2* S1 RED-2: #{inspect(@boot)} is not available"

    assert function_exported?(@boot, :runtime_config!, 2),
           "C2* S1 RED-2: #{inspect(@boot)}.runtime_config!/2 is not exported"
  end

  defp runtime_config!(config_env, env) do
    require_boot!()
    apply(@boot, :runtime_config!, [config_env, env])
  end

  # The accepted configuration, merged as `config/2` would apply it.
  defp accepted!(config_env, env) do
    result = runtime_config!(config_env, env)

    assert is_list(result) and
             Enum.all?(result, &match?({app, kw} when is_atom(app) and is_list(kw), &1)),
           "C2* S1 P2: runtime_config!/2 must return [{app, keyword}]: #{inspect(result)}"

    Enum.reduce(result, [], fn entry, acc -> Config.Reader.merge(acc, [entry]) end)
  end

  defp refusal(config_env, env) do
    result = runtime_config!(config_env, env)
    flunk("C2* S1 P2: the boot was accepted: #{inspect(result)}")
  rescue
    error in RuntimeError -> Exception.message(error)
  end

  defp refused(reason), do: "agent environment refused at boot (#{reason})"

  defp selected(ctx, step, extra \\ %{}) do
    Map.merge(
      %{"HOME" => ctx.home, "SDR_AGENT_ENV" => "agentenv-1", "SDR_AGENT_ENV_STEP" => step},
      extra
    )
  end

  defp agent_env(config), do: get_in(config, [:sdr_agent, SdrAgent.AgentEnv])

  defp assert_target(config) do
    repo = get_in(config, [:sdr_agent, SdrAgent.Repo])

    assert {repo[:database], repo[:hostname], repo[:port]} ==
             {"sdr_agent_agentenv", "localhost", 5520},
           "C2* S1 L1: the Repo target must be forced: #{inspect(repo)}"

    assert get_in(config, [:sdr_agent, :otel_capture_content]) == false

    # Codex c9a6f6c7 R4: PR-A's OperationSnapshot reads this database key.
    assert agent_env(config)[:database] == "sdr_agent_agentenv",
           "C2* S1 P2: the AgentEnv configuration must name the fixed database: " <>
             inspect(agent_env(config))
  end

  defp assert_restricted(config) do
    assert get_in(config, [:sdr_agent, :model_provider]) == @fake
    assert get_in(config, [:sdr_agent, SdrAgentWeb.Endpoint, :server]) == false
  end

  # A bootstrap lease at `step` with the receipts of `done`.
  defp bootstrap_env(ctx, step, done, extra \\ %{}) do
    %{nonce: nonce} =
      BootFx.bootstrap!(ctx.root,
        done: done,
        database: "sdr_agent_agentenv",
        database_oid: 424_242
      )

    {nonce, selected(ctx, step, Map.put(extra, "SDR_AGENT_ENV_NONCE", nonce))}
  end

  defp provisioning_env(ctx, extra \\ %{}) do
    bound = BootFx.agentenv_bound!(ctx.root, lease: :provisioning)
    {bound, selected(ctx, "provision", Map.put(extra, "SDR_AGENT_ENV_NONCE", bound.nonce))}
  end

  defp run_env(ctx, extra \\ %{}) do
    bound = BootFx.agentenv_bound!(ctx.root, lease: :run)

    env =
      selected(
        ctx,
        "run",
        Map.merge(
          %{
            "SDR_AGENT_ENV_NONCE" => bound.nonce,
            "SDR_WITNESS_STORE_ROOT" => Path.join(ctx.root, "evidence"),
            "SDR_ANCHOR_SINKS" => "file",
            "SDR_ANCHOR_FILE_DIR" => Path.join(ctx.root, "anchors")
          },
          extra
        )
      )

    {bound, env}
  end

  defp drop_var(env, name), do: Map.delete(env, name)

  ## Inert

  describe "inert" do
    test "without the selector variables the configuration is empty in every environment", ctx do
      unrelated = %{
        "HOME" => ctx.home,
        "PATH" => "/usr/bin:/bin",
        "PORT" => "4122",
        "PHX_SERVER" => "true",
        "SDR_MODEL_PROVIDER" => "fake",
        "SDR_DEMO_EXCEPTION" => "c2star-demo-v4/1"
      }

      for config_env <- [:dev, :test, :prod], env <- [%{}, unrelated] do
        assert runtime_config!(config_env, env) == [],
               "C2* S1 AC1: an unset selector must leave #{config_env}'s configuration unchanged"
      end
    end
  end

  ## The selector

  describe "selector" do
    test "agentenv-1 is refused in test and prod", ctx do
      for config_env <- [:test, :prod], step <- ["check", "run"] do
        assert refusal(config_env, selected(ctx, step)) == refused(:not_dev)
      end
    end

    test "any other selector value is refused in dev", ctx do
      for value <- ["bogus", "", "agentenv-2", "AGENTENV-1", " agentenv-1"] do
        env = Map.put(selected(ctx, "check"), "SDR_AGENT_ENV", value)
        assert refusal(:dev, env) == refused(:unknown_environment), inspect(value)
      end
    end

    test "a step or nonce variable without the selector is refused in every environment", ctx do
      for config_env <- [:dev, :test, :prod],
          stray <- [
            %{"SDR_AGENT_ENV_STEP" => "run"},
            %{"SDR_AGENT_ENV_STEP" => ""},
            %{"SDR_AGENT_ENV_NONCE" => Fx.nonce()}
          ] do
        env = Map.put(stray, "HOME", ctx.home)
        assert refusal(config_env, env) == refused(:stray_variables), inspect({config_env, stray})
      end
    end

    test "an unknown or missing step is refused", ctx do
      for step <- ["reset", "drop", "", "Run", "check "] do
        assert refusal(:dev, selected(ctx, step)) == refused(:unknown_step), inspect(step)
      end

      assert refusal(:dev, ctx |> selected("check") |> drop_var("SDR_AGENT_ENV_STEP")) ==
               refused(:unknown_step)
    end
  end

  ## The pre-lease check step

  describe "check" do
    test "check needs no lease and forces the target", ctx do
      config = accepted!(:dev, selected(ctx, "check"))

      assert Keyword.take(agent_env(config), [:root, :mode, :step]) |> Enum.sort() ==
               Enum.sort(root: ctx.root, mode: :check, step: :check)

      assert_target(config)
      assert BootFx.state_files(ctx.root) == [], "C2* S1 P2: the check step writes nothing"
    end

    test "SDR_DEMO_EXCEPTION presence is not refused by S1 in check mode", ctx do
      env = selected(ctx, "check", %{"SDR_DEMO_EXCEPTION" => "c2star-demo-v4/1"})
      assert agent_env(accepted!(:dev, env))[:mode] == :check
    end
  end

  ## The effective Repo target (Codex c9a6f6c7 R4)

  describe "effective target" do
    # Synthetic only: no credentials, and nothing connects anywhere.
    @conflicting_repo [
      url: "ecto://synthetic:synthetic@elsewhere.invalid:1/other_db",
      hostname: "elsewhere.invalid",
      port: 1,
      database: "other_db",
      socket_dir: "/nonexistent",
      socket: "/nonexistent/.s.PGSQL.1",
      endpoints: [{"elsewhere.invalid", 1}]
    ]

    @conflicting_env %{
      "DATABASE_URL" => "ecto://synthetic:synthetic@elsewhere.invalid:1/other_db",
      "PGHOST" => "elsewhere.invalid",
      "PGPORT" => "1",
      "PGDATABASE" => "other_db"
    }

    test "no URL, socket or endpoint override can take precedence over the fixed target", ctx do
      for mode <- [:check, :bootstrap, :provisioning, :run] do
        File.rm_rf!(Path.join(ctx.root, "state"))
        File.mkdir_p!(Path.join(ctx.root, "state"))
        env = Map.merge(mode_env(ctx, mode), @conflicting_env)
        produced = accepted!(:dev, env)
        merged = Config.Reader.merge([sdr_agent: [{SdrAgent.Repo, @conflicting_repo}]], produced)
        repo = get_in(merged, [:sdr_agent, SdrAgent.Repo])

        assert {repo[:database], repo[:hostname], repo[:port]} ==
                 {"sdr_agent_agentenv", "localhost", 5520},
               "C2* S1 P2 (#{mode}): the fixed target must win: #{inspect(repo)}"

        for key <- [:url, :socket, :socket_dir, :endpoints] do
          assert repo[key] == nil,
                 "C2* S1 P2 (#{mode}): #{key} must not override the fixed target: #{inspect(repo)}"
        end

        assert agent_env(produced)[:database] == "sdr_agent_agentenv"
      end
    end
  end

  # An accepted control environment of `mode` (fresh state files).
  defp mode_env(ctx, :check), do: selected(ctx, "check")
  defp mode_env(ctx, :run), do: ctx |> run_env() |> elem(1)
  defp mode_env(ctx, mode), do: ctx |> non_run_env(mode, %{}) |> elem(1)

  ## Non-run modes (L1)

  describe "non-run refusals" do
    test "bootstrap control: a leased seed step is accepted and restricted", ctx do
      {nonce, env} = bootstrap_env(ctx, "seed", [:create, :migrate])
      config = accepted!(:dev, env)

      assert Keyword.take(agent_env(config), [:root, :mode, :step, :nonce]) |> Enum.sort() ==
               Enum.sort(root: ctx.root, mode: :bootstrap, step: :seed, nonce: nonce)

      assert_target(config)
      assert_restricted(config)
    end

    test "provisioning control: a leased provision step is accepted and restricted", ctx do
      {bound, env} = provisioning_env(ctx)
      config = accepted!(:dev, env)

      assert Keyword.take(agent_env(config), [:root, :mode, :step, :nonce]) |> Enum.sort() ==
               Enum.sort(
                 root: ctx.root,
                 mode: :provisioning,
                 step: :provision,
                 nonce: bound.nonce
               )

      assert_target(config)
      assert_restricted(config)
    end

    test "every step of the bootstrap order is accepted after its predecessor", ctx do
      for {step, done} <- [
            create: [],
            migrate: [:create],
            seed: [:create, :migrate],
            probe: [:create, :migrate, :seed]
          ] do
        File.rm_rf!(Path.join(ctx.root, "state"))
        {_nonce, env} = bootstrap_env(ctx, Atom.to_string(step), done)
        assert agent_env(accepted!(:dev, env))[:step] == step
      end
    end

    for mode <- [:bootstrap, :provisioning] do
      @mode mode

      test "#{mode}: a model provider other than unset or fake is refused", ctx do
        for provider <- ["claude_cli", "bogus", ""] do
          {_bound, env} = non_run_env(ctx, @mode, %{"SDR_MODEL_PROVIDER" => provider})
          assert refusal(:dev, env) == refused(:provider_refused), inspect(provider)
        end

        {_bound, env} = non_run_env(ctx, @mode, %{"SDR_MODEL_PROVIDER" => "fake"})
        assert agent_env(accepted!(:dev, env))[:mode] == @mode
      end

      test "#{mode}: SDR_DEMO_EXCEPTION present at all is refused", ctx do
        for value <- ["", "c2star-demo-v4/1", "other"] do
          {_bound, env} = non_run_env(ctx, @mode, %{"SDR_DEMO_EXCEPTION" => value})
          assert refusal(:dev, env) == refused(:selector_refused), inspect(value)
        end
      end

      test "#{mode}: PHX_SERVER present at all is refused", ctx do
        for value <- ["true", ""] do
          {_bound, env} = non_run_env(ctx, @mode, %{"PHX_SERVER" => value})
          assert refusal(:dev, env) == refused(:phx_server_refused), inspect(value)
        end
      end

      test "#{mode}: a nonce other than the lease's, or none, is refused", ctx do
        {_bound, env} = non_run_env(ctx, @mode, %{})

        assert refusal(:dev, %{env | "SDR_AGENT_ENV_NONCE" => Fx.nonce()}) ==
                 refused(:agent_env_lease_mismatch)

        assert refusal(:dev, drop_var(env, "SDR_AGENT_ENV_NONCE")) ==
                 refused(:agent_env_lease_mismatch)
      end

      test "#{mode}: a missing or invalid lease is refused", ctx do
        {_bound, env} = non_run_env(ctx, @mode, %{})
        lease = Fx.path(ctx.root, :lease)
        File.rm!(lease)
        assert refusal(:dev, env) == refused(:lease_missing)

        File.write!(lease, "{\"mode\":\"bootstrap\"}\n")
        assert refusal(:dev, env) == refused(:lease_invalid)
      end
    end

    # The lease's mode is checked before the nonce, the target and the step
    # order (a provisioning nonce has no bootstrap history). The run step's
    # own case, with the run variables set, is in "run".
    test "a step for another lease mode is refused", ctx do
      {_nonce, env} = bootstrap_env(ctx, "seed", [:create, :migrate])

      assert refusal(:dev, %{env | "SDR_AGENT_ENV_STEP" => "provision"}) ==
               refused(:step_mode_mismatch)

      File.rm_rf!(Path.join(ctx.root, "state"))
      {_bound, env} = provisioning_env(ctx)

      for step <- ["create", "migrate", "seed", "probe"] do
        assert refusal(:dev, %{env | "SDR_AGENT_ENV_STEP" => step}) ==
                 refused(:step_mode_mismatch),
               step
      end
    end

    test "a bootstrap step out of order, or repeated, is refused", ctx do
      {_nonce, env} = bootstrap_env(ctx, "seed", [:create])
      assert refusal(:dev, env) == refused(:step_out_of_order)

      File.rm_rf!(Path.join(ctx.root, "state"))
      {_nonce, env} = bootstrap_env(ctx, "seed", [:create, :migrate, :seed])
      assert refusal(:dev, env) == refused(:step_out_of_order)

      File.rm_rf!(Path.join(ctx.root, "state"))
      {_nonce, env} = bootstrap_env(ctx, "create", [:create])
      assert refusal(:dev, env) == refused(:step_out_of_order)
    end

    test "a bootstrap step on a created database of another target or nonce is refused", ctx do
      %{nonce: nonce} =
        BootFx.bootstrap!(ctx.root,
          done: [:create],
          database: "sdr_agent_dev",
          database_oid: 424_242
        )

      env = selected(ctx, "migrate", %{"SDR_AGENT_ENV_NONCE" => nonce})
      assert refusal(:dev, env) == refused(:bootstrap_target_mismatch)

      File.rm_rf!(Path.join(ctx.root, "state"))

      %{nonce: nonce} =
        BootFx.bootstrap!(ctx.root,
          done: [:create],
          database: "sdr_agent_agentenv",
          database_oid: 424_242,
          created_nonce: Fx.nonce()
        )

      env = selected(ctx, "migrate", %{"SDR_AGENT_ENV_NONCE" => nonce})
      assert refusal(:dev, env) == refused(:bootstrap_target_mismatch)
    end

    test "a provisioning lease whose binding is not the environment's is refused", ctx do
      {_bound, env} = provisioning_env(ctx)
      Fx.tamper!(ctx.root, :environment)
      assert refusal(:dev, env) == refused(:agent_env_lease_mismatch)
    end
  end

  defp non_run_env(ctx, :bootstrap, extra) do
    {nonce, env} = bootstrap_env(ctx, "seed", [:create, :migrate], extra)
    {%{nonce: nonce}, env}
  end

  defp non_run_env(ctx, :provisioning, extra), do: provisioning_env(ctx, extra)

  ## Run mode

  describe "run" do
    test "control: a bound run lease is accepted with the fixed port and target", ctx do
      {bound, env} = run_env(ctx)

      for env <- [env, Map.put(env, "PORT", "4130")] do
        config = accepted!(:dev, env)

        assert Keyword.take(agent_env(config), [:root, :mode, :step, :nonce]) |> Enum.sort() ==
                 Enum.sort(root: ctx.root, mode: :run, step: :run, nonce: bound.nonce)

        http = get_in(config, [:sdr_agent, SdrAgentWeb.Endpoint, :http])
        assert {http[:ip], http[:port]} == {{127, 0, 0, 1}, 4130}
        assert_target(config)
      end
    end

    test "a port other than 4130 is refused", ctx do
      {_bound, env} = run_env(ctx)

      for port <- ["4120", "4122", "4002", "4000", "", "abc"] do
        assert refusal(:dev, Map.put(env, "PORT", port)) == refused(:port_refused), inspect(port)
      end
    end

    test "anchors other than the file sink under the root are refused", ctx do
      {_bound, env} = run_env(ctx)

      for {sinks, dir} <- [
            {nil, nil},
            {"git+ots", nil},
            {"none", nil},
            {"file", nil},
            {"file", "tmp/audit-anchors"},
            {"file", Path.expand("tmp/audit-anchors")},
            {"file", Path.join(ctx.root, "state")},
            {"file", Path.join([ctx.root, "anchors", "..", "state"])}
          ] do
        env =
          env
          |> Map.merge(%{"SDR_ANCHOR_SINKS" => sinks, "SDR_ANCHOR_FILE_DIR" => dir})
          |> Map.reject(fn {_name, value} -> is_nil(value) end)

        assert refusal(:dev, env) == refused(:anchor_sinks_refused), inspect({sinks, dir})
      end
    end

    # Codex c9a6f6c7 Q6: containment is physical, not lexical.
    test "an anchor directory that escapes the root through a symlink is refused", ctx do
      {_bound, env} = run_env(ctx)
      outside = Fx.root!("outside")
      escape = Path.join([ctx.root, "anchors", "escape"])
      :ok = File.ln_s(outside, escape)

      assert refusal(:dev, Map.put(env, "SDR_ANCHOR_FILE_DIR", escape)) ==
               refused(:anchor_sinks_refused)

      inside = Path.join([ctx.root, "anchors", "inside"])
      File.mkdir_p!(inside)

      assert agent_env(accepted!(:dev, Map.put(env, "SDR_ANCHOR_FILE_DIR", inside)))[:mode] ==
               :run
    end

    test "a missing witness root is refused", ctx do
      {_bound, env} = run_env(ctx)

      assert refusal(:dev, drop_var(env, "SDR_WITNESS_STORE_ROOT")) ==
               refused(:witness_root_missing)
    end

    test "an unbound environment is refused", ctx do
      {_bound, env} = run_env(ctx)
      environment = Fx.path(ctx.root, :environment)
      File.write!(environment, "not json")
      assert refusal(:dev, env) == refused(:environment_unbound)

      File.rm!(environment)
      assert refusal(:dev, env) == refused(:environment_unbound)
    end

    test "a run lease of another nonce or binding is refused", ctx do
      {_bound, env} = run_env(ctx)

      assert refusal(:dev, %{env | "SDR_AGENT_ENV_NONCE" => Fx.nonce()}) ==
               refused(:agent_env_lease_mismatch)

      Fx.tamper!(ctx.root, :environment)
      assert refusal(:dev, env) == refused(:agent_env_lease_mismatch)
    end

    test "a provisioning or bootstrap lease cannot boot run", ctx do
      {bound, env} = provisioning_env(ctx)

      run =
        Map.merge(env, %{
          "SDR_AGENT_ENV_STEP" => "run",
          "SDR_AGENT_ENV_NONCE" => bound.nonce,
          "SDR_WITNESS_STORE_ROOT" => Path.join(ctx.root, "evidence"),
          "SDR_ANCHOR_SINKS" => "file",
          "SDR_ANCHOR_FILE_DIR" => Path.join(ctx.root, "anchors")
        })

      assert refusal(:dev, run) == refused(:step_mode_mismatch)

      File.rm_rf!(Path.join(ctx.root, "state"))
      {nonce, _env} = bootstrap_env(ctx, "seed", [:create, :migrate])

      assert refusal(:dev, %{run | "SDR_AGENT_ENV_NONCE" => nonce}) ==
               refused(:step_mode_mismatch)
    end

    test "claude_cli with only the authorization claim is refused at P2 (SpendReady, S1 fail-closed)",
         ctx do
      {bound, env} = run_env(ctx, %{"SDR_MODEL_PROVIDER" => "claude_cli"})

      Fx.write_state!(ctx.root, :claim, %{
        "authorization_id" => Ecto.UUID.generate(),
        "authorization_sha256" => Fx.hex(32),
        "binding_sha256" => bound.binding_sha256,
        "nonce" => Fx.nonce(),
        "claimed_at" => DateTime.utc_now()
      })

      assert refusal(:dev, env) == refused(:agent_env_not_spend_ready)
    end

    test "P5-2(b): an existing run receipt for the nonce is refused, and nothing is written",
         ctx do
      {bound, env} = run_env(ctx)

      receipt =
        Canonical.encode!(%{
          "nonce" => bound.nonce,
          "boot_id" => Fx.hex(16),
          "completed_at" => DateTime.utc_now()
        })

      path = BootFx.run_receipt_path(ctx.root, bound.nonce)
      File.write!(path, receipt)
      before = BootFx.state_files(ctx.root)

      assert refusal(:dev, env) == refused(:run_receipt_exists)
      assert File.read!(path) == receipt
      assert BootFx.state_files(ctx.root) == before
    end
  end

  ## Wiring in config/runtime.exs (behavioural)

  defp read_runtime!(config_env),
    do: Config.Reader.read!("config/runtime.exs", env: config_env, target: :host)

  describe "wiring" do
    setup do
      BootFx.put_os_env!(Map.new(@selector_vars, &{&1, nil}))
    end

    test "config/runtime.exs refuses the selector in test" do
      BootFx.put_os_env!(%{"SDR_AGENT_ENV" => "agentenv-1", "SDR_AGENT_ENV_STEP" => "check"})

      assert_raise RuntimeError, refused(:not_dev), fn -> read_runtime!(:test) end
    end

    test "config/runtime.exs refuses an unknown selector value in dev" do
      BootFx.put_os_env!(%{"SDR_AGENT_ENV" => "bogus"})

      assert_raise RuntimeError, refused(:unknown_environment), fn -> read_runtime!(:dev) end
    end

    test "control: an unset selector leaves no agent-environment configuration" do
      for config_env <- [:dev, :test] do
        refute get_in(read_runtime!(config_env), [:sdr_agent, SdrAgent.AgentEnv])
      end
    end
  end
end

defmodule SdrAgent.AgentEnv.RuntimeEnforcementTest do
  @moduledoc """
  C2* S1 PR-B RED-2: runtime enforcement of the agent environment's modes
  (plan `claude-c2star-s1-environment-plan-r2.md` section 6.2 L2-L4 and L6,
  the run tree, T-V9 (runtime), OQ 8/9):

    * **"children"** — `Boot.children(mode, base)`: `:none` returns `base`
      unchanged; the non-run tree is exactly Telemetry, Repo,
      `{Instance, mode}` and PubSub (no DNSCluster, model tree, Oban,
      Relay, Endpoint or AshAuthentication); the run tree is `base` with
      `{Instance, :run}` immediately after the Repo and Oban configured by
      `Boot.oban_config(:run, base)`: exactly the queues `default: 10,
      research: 20, delivery: 5, reconciliation: 1` and one Cron with the
      four crons of `config.exs` other than `OtsUpgradeWorker`, every other
      Oban option kept.
    * **"start"** — `Boot.check_start!/0` (`Application.start/2`, first
      line): refuses check mode, and in bootstrap and provisioning a
      missing step declaration or `:phoenix, :serve_endpoints` (`mix
      phx.server`).
    * **"repo"** — `Boot.check_repo_start!/1` (`SdrAgent.Repo.init/2`):
      enforces only `:supervisor`; `:runtime` (`Repo.config/0`) always
      passes. `Boot.declare_step!/1` records the step task's declaration,
      which must be the configured step.
    * **"entries in non-run modes"** and **"seed under bootstrap"** —
      regression locks of GREEN-1's L6 (they pass at RED): a Fake
      reservation raises `ModeRefused` and writes nothing, and the demo
      seed succeeds under bootstrap with no entry reached and no job.

  Refusals are `RuntimeError`s with the fixed message `"agent environment
  refused at boot (<reason>)"`.

  RED: `SdrAgent.AgentEnv.Boot` does not exist (structural, guarded after
  the fixtures) and `SdrAgent.Repo.init/2` starts in every mode (the repo
  wiring row; behavioural).

  Hermetic: SQL sandbox, physical roots under `tmp/agent-env-roots`, no
  port, process start, real Mix or CLI.
  """
  use SdrAgent.AuditCase, async: false
  use Oban.Testing, repo: SdrAgent.Repo

  alias SdrAgent.Agents
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @boot SdrAgent.AgentEnv.Boot
  @instance SdrAgent.AgentEnv.Instance
  @mode_refused SdrAgent.AgentEnv.ModeRefused

  @boot_api [children: 2, oban_config: 2, check_start!: 0, check_repo_start!: 1, declare_step!: 1]

  @run_queues [default: 10, research: 20, delivery: 5, reconciliation: 1]
  @run_crontab [
    {"* * * * *", SdrAgent.Audit.AnchorWorker},
    {"* * * * *", SdrAgent.Outreach.StaleDeliverySweeper},
    {"*/5 * * * *", SdrAgent.Agents.Witness.ScanWorker},
    {"*/5 * * * *", SdrAgent.SDR.StaleRunSweeper}
  ]

  # The six children no non-run tree may contain (section 6.2 L4).
  @omitted [
    DNSCluster,
    SdrAgent.AI.ModelProvider.ProfileSupervisor,
    Oban,
    SdrAgent.LiveEvents.Relay,
    SdrAgentWeb.Endpoint,
    AshAuthentication.Supervisor
  ]

  setup do
    tenant = bootstrap!()
    root = Fx.root!("enforcement")
    Fx.unconfigure!()
    BootFx.preserve_app_env!(:sdr_agent)
    BootFx.preserve_app_env!(:phoenix)
    Application.delete_env(:phoenix, :serve_endpoints)
    %{tenant: tenant, root: root}
  end

  ## Helpers

  defp require_boot! do
    assert Code.ensure_loaded?(@boot), "C2* S1 RED-2: #{inspect(@boot)} is not available"

    for {function, arity} <- @boot_api do
      assert function_exported?(@boot, function, arity),
             "C2* S1 RED-2: #{inspect(@boot)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp boot(function, args) do
    require_boot!()
    apply(@boot, function, args)
  end

  defp refused(reason), do: "agent environment refused at boot (#{reason})"

  # Today's tree, with the model tree a ClaudeCLI configuration would add,
  # so every omitted child is present in `base`.
  defp base do
    SdrAgent.Telemetry.test_children() ++
      [
        SdrAgentWeb.Telemetry,
        SdrAgent.Repo,
        {DNSCluster, query: :ignore},
        {SdrAgent.AI.ModelProvider.ProfileSupervisor,
         server: &SdrAgent.AI.ModelProvider.Runtime.server_options/1},
        {Oban, Application.fetch_env!(:sdr_agent, Oban)},
        {Phoenix.PubSub, name: SdrAgent.PubSub},
        SdrAgent.LiveEvents.Relay,
        SdrAgentWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :sdr_agent]}
      ]
  end

  defp module_of({module, _arg}) when is_atom(module), do: module
  defp module_of(%{start: {module, _function, _args}}), do: module
  defp module_of(module) when is_atom(module), do: module

  defp configure!(ctx, mode, step),
    do: Fx.configure!(ctx.root, mode: mode, nonce: Fx.nonce(), step: step)

  defp declared!(ctx, mode, step) do
    configure!(ctx, mode, step)
    assert boot(:declare_step!, [step]) == :ok
  end

  ## Children (L4)

  describe "children" do
    test ":none returns the base tree unchanged" do
      assert boot(:children, [:none, base()]) == base()
    end

    test "control: the application's own tree is today's, unconfigured" do
      modules = Enum.map(SdrAgent.Application.children(), &module_of/1)
      assert Oban in modules and SdrAgentWeb.Endpoint in modules
      refute @instance in modules
    end

    for mode <- [:bootstrap, :provisioning] do
      @mode mode

      test "#{mode}: the tree is exactly Telemetry, Repo, Instance and PubSub" do
        children = boot(:children, [@mode, base()])

        assert children ==
                 SdrAgent.Telemetry.test_children() ++
                   [
                     SdrAgentWeb.Telemetry,
                     SdrAgent.Repo,
                     {@instance, @mode},
                     {Phoenix.PubSub, name: SdrAgent.PubSub}
                   ]

        modules = Enum.map(children, &module_of/1)

        for omitted <- @omitted do
          refute omitted in modules,
                 "C2* S1 L4: #{inspect(omitted)} must not start in #{@mode} mode"
        end
      end
    end

    test "run: the base tree plus Instance after the Repo, with the run Oban configuration" do
      children = boot(:children, [:run, base()])
      base_modules = Enum.map(base(), &module_of/1)

      {before_repo, [SdrAgent.Repo | after_repo]} =
        Enum.split_while(base_modules, &(&1 != SdrAgent.Repo))

      assert Enum.map(children, &module_of/1) ==
               before_repo ++ [SdrAgent.Repo, @instance | after_repo]

      assert {@instance, :run} in children

      assert [{Oban, oban}] = Enum.filter(children, &(module_of(&1) == Oban))
      assert oban == boot(:oban_config, [:run, Application.fetch_env!(:sdr_agent, Oban)])

      kept = Enum.reject(base(), &(module_of(&1) == Oban))
      assert Enum.reject(children, &(module_of(&1) in [Oban, @instance])) == kept
    end

    test "run: Oban has exactly four queues and four crons, every other option kept" do
      base = Application.fetch_env!(:sdr_agent, Oban)
      oban = boot(:oban_config, [:run, base])

      assert oban[:queues] == @run_queues
      assert oban[:plugins] == [{Oban.Plugins.Cron, crontab: @run_crontab}]
      assert Keyword.drop(oban, [:queues, :plugins]) == Keyword.drop(base, [:queues, :plugins])

      for dropped <- [:followup, :integration, :agent] do
        refute Keyword.has_key?(oban[:queues], dropped)
      end

      crons =
        for {Oban.Plugins.Cron, opts} <- oban[:plugins],
            {_schedule, worker} <- opts[:crontab],
            do: worker

      refute SdrAgent.Audit.OtsUpgradeWorker in crons
    end
  end

  ## Application start (L3)

  describe "start" do
    test "inert: the start check passes unconfigured" do
      assert boot(:check_start!, []) == :ok
    end

    test "check mode never starts the application", ctx do
      configure!(ctx, :check, :check)
      assert_raise RuntimeError, refused(:undeclared_step), fn -> boot(:check_start!, []) end
    end

    for {mode, step} <- [bootstrap: :seed, provisioning: :provision] do
      @mode mode
      @step step

      test "#{mode}: the start needs the step task's declaration", ctx do
        configure!(ctx, @mode, @step)
        assert_raise RuntimeError, refused(:undeclared_step), fn -> boot(:check_start!, []) end

        assert boot(:declare_step!, [@step]) == :ok
        assert boot(:check_start!, []) == :ok
      end

      test "#{mode}: a server start (mix phx.server) is refused even when declared", ctx do
        declared!(ctx, @mode, @step)
        Application.put_env(:phoenix, :serve_endpoints, true)

        assert_raise RuntimeError, refused(:server_refused), fn -> boot(:check_start!, []) end
      end
    end

    test "run: the start check passes with or without a server", ctx do
      configure!(ctx, :run, :run)
      assert boot(:check_start!, []) == :ok

      Application.put_env(:phoenix, :serve_endpoints, true)
      assert boot(:check_start!, []) == :ok
    end

    test "a declaration other than the configured step is refused", ctx do
      configure!(ctx, :bootstrap, :seed)

      for step <- [:create, :migrate, :probe, :provision] do
        assert_raise RuntimeError, refused(:undeclared_step), fn ->
          boot(:declare_step!, [step])
        end
      end

      assert_raise RuntimeError, refused(:undeclared_step), fn -> boot(:check_start!, []) end
    end
  end

  ## Repo start (L2)

  describe "repo" do
    test "inert and run: the Repo starts", ctx do
      assert boot(:check_repo_start!, [:supervisor]) == :ok

      configure!(ctx, :run, :run)
      assert boot(:check_repo_start!, [:supervisor]) == :ok
    end

    test "check mode never starts the Repo; its runtime config still resolves", ctx do
      configure!(ctx, :check, :check)

      assert_raise RuntimeError, refused(:undeclared_step), fn ->
        boot(:check_repo_start!, [:supervisor])
      end

      assert boot(:check_repo_start!, [:runtime]) == :ok
    end

    for {mode, step} <- [bootstrap: :migrate, provisioning: :provision] do
      @mode mode
      @step step

      test "#{mode}: the Repo starts only after the declaration", ctx do
        configure!(ctx, @mode, @step)

        assert_raise RuntimeError, refused(:undeclared_step), fn ->
          boot(:check_repo_start!, [:supervisor])
        end

        assert boot(:check_repo_start!, [:runtime]) == :ok
        assert boot(:declare_step!, [@step]) == :ok
        assert boot(:check_repo_start!, [:supervisor]) == :ok
      end
    end

    test "wiring: SdrAgent.Repo.init/2 enforces the declaration on a supervisor start", ctx do
      config = Repo.config()
      assert {:ok, _config} = Repo.init(:supervisor, config)

      configure!(ctx, :bootstrap, :seed)
      assert {:ok, _config} = Repo.init(:runtime, config)

      assert_raise RuntimeError, refused(:undeclared_step), fn ->
        Repo.init(:supervisor, config)
      end
    end
  end

  ## Entries and the permitted seed in non-run modes (L6; regression locks)

  describe "entries in non-run modes" do
    for {mode, step} <- [check: :check, bootstrap: :seed, provisioning: :provision] do
      @mode mode
      @step step

      test "#{mode}: a Fake model reservation raises ModeRefused and writes nothing", ctx do
        configure!(ctx, @mode, @step)
        before = invocation_count()
        run = %{id: Ecto.UUID.generate(), tenant_id: ctx.tenant.id}

        assert_raise @mode_refused, fn ->
          Agents.reserve_model_invocation(run, %{},
            actor: system_actor(:agent_runtime, ctx.tenant)
          )
        end

        assert invocation_count() == before
      end
    end
  end

  defp invocation_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM model_invocations")
    count
  end

  describe "seed under bootstrap" do
    test "the demo seed succeeds with no snapshot entry reached and no job enqueued", ctx do
      configure!(ctx, :bootstrap, :seed)

      {result, events} = Fx.trace_snapshots(fn -> Seed.run() end)

      assert {:ok, %{created: created}} = result
      assert created > 0
      assert events == [], "C2* S1 L6: the permitted seed reached an entry: #{inspect(events)}"
      assert all_enqueued() == []
    end
  end
end

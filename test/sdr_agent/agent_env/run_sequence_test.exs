defmodule SdrAgent.AgentEnv.RunSequenceTest do
  @moduledoc """
  C2* S1 PR-B RED-3: the successful Fake run sequence across phases P0-P5
  (plan `claude-c2star-s1-environment-plan-r2.md` section 6.1, F3, as moved
  to RED-3 by `claude-c2star-s1-prb-p5-correction-r1.md` section 4 and Codex
  `e01021f5` binding detail 6):

  `Launcher.check/1` passes (the Fake: `SpendReady.preflight/1` is not
  called) → `State.acquire_lease(root, :run, [])` → `Boot.runtime_config!/2`
  gives the run configuration for that nonce → `Boot.children(:run, base)`
  has `{Instance, :run}` → `Instance.init(:run)` boots once (marker and
  binding) → an orderly synthetic top stop through `Shutdown.plan/2` and
  `complete/2` (test-build seams for the synthetic top only; the binding and
  root are the production ones) writes the receipt → `State.release(root,
  :run, nonce)` → `State.classify/2` is `{:bound, _}` again, with the
  marker and the receipt kept. With `claude_cli` requested, P0 refuses
  before any lease.

  These are unit proofs across the phase seams, not a whole-VM SIGTERM proof
  (S5's owned live run is).

  RED: `Launcher` and State's writers do not exist (structural, guarded
  after the fixtures).

  Hermetic: SQL sandbox, a fake HOME under `tmp/agent-env-roots`, an
  injected port probe and synthetic processes; no port, real Mix, CLI, VM
  or application stop.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AgentEnv
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @launcher SdrAgent.AgentEnv.Launcher
  @state SdrAgent.AgentEnv.State
  @boot SdrAgent.AgentEnv.Boot
  @instance SdrAgent.AgentEnv.Instance
  @shutdown SdrAgent.AgentEnv.Shutdown
  @spend_ready SdrAgent.AgentEnv.SpendReady
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]

  setup do
    tenant = bootstrap!()
    %{home: home, root: root} = BootFx.home!()

    for dir <- @subdirectories do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    Fx.unconfigure!()
    BootFx.preserve_app_env!(:sdr_agent)
    BootFx.erase_boot_binding!()
    %{tenant: tenant, home: home, root: root}
  end

  ## Helpers

  defp require!(module, functions) do
    assert Code.ensure_loaded?(module), "C2* S1 RED-3: #{inspect(module)} is not available"

    for {function, arity} <- functions do
      assert function_exported?(module, function, arity),
             "C2* S1 RED-3: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp require_all! do
    require!(@launcher, check: 1)
    require!(@state, acquire_lease: 3, release: 3, classify: 2)
    require!(@boot, runtime_config!: 2, children: 2)
    require!(@instance, init: 1)
    require!(@shutdown, plan: 2, complete: 2)
  end

  defp launcher_inputs(ctx, env) do
    build = Path.join([ctx.root, "build", "dev"])
    File.mkdir_p!(build)

    %{
      intent: :run,
      env: env,
      root: ctx.root,
      build_path: build,
      deps_path: Path.join(ctx.root, "deps"),
      config: %{
        repo: [database: "sdr_agent_agentenv", hostname: "localhost", port: 5520],
        endpoint_http: [ip: {127, 0, 0, 1}, port: 4130],
        anchor_sinks: [{:file, FileSink, directory: Path.join(ctx.root, "anchors")}],
        witness_store_root: Path.join(ctx.root, "evidence"),
        suppression_check: SdrAgent.SDR.SuppressionCheck.Store,
        otel_capture_content: false
      },
      connect: fn _ip, _port -> {:error, :econnrefused} end
    }
  end

  defp run_env(ctx, nonce) do
    %{
      "HOME" => ctx.home,
      "SDR_AGENT_ENV" => "agentenv-1",
      "SDR_AGENT_ENV_STEP" => "run",
      "SDR_AGENT_ENV_NONCE" => nonce,
      "SDR_WITNESS_STORE_ROOT" => Path.join(ctx.root, "evidence"),
      "SDR_ANCHOR_SINKS" => "file",
      "SDR_ANCHOR_FILE_DIR" => Path.join(ctx.root, "anchors")
    }
  end

  defp merged(result), do: Enum.reduce(result, [], &Config.Reader.merge(&2, [&1]))

  ## The sequence

  test "the successful Fake run sequence: check, lease, boot, orderly exit, release, bound",
       ctx do
    bound = Fx.bound!(ctx.root, lease: :none)
    require_all!()

    # P0: readiness, with no lease taken and SpendReady not consulted (Fake).
    {check, spend_calls} =
      BootFx.trace_calls(@spend_ready, fn ->
        apply(@launcher, :check, [launcher_inputs(ctx, %{})])
      end)

    assert check == :ok
    assert spend_calls == []
    refute File.exists?(Fx.path(ctx.root, :lease))

    # P1: the run lease, targeting the binding.
    assert {:ok, nonce} = apply(@state, :acquire_lease, [ctx.root, :run, []])

    assert BootFx.read_object!(Fx.path(ctx.root, :lease))["target"] ==
             %{"binding_sha256" => bound.binding_sha256}

    # P2: the leased configuration for that nonce.
    config = merged(apply(@boot, :runtime_config!, [:dev, run_env(ctx, nonce)]))
    agent_env = get_in(config, [:sdr_agent, AgentEnv])

    assert Keyword.take(agent_env, [:root, :mode, :step, :nonce]) |> Enum.sort() ==
             Enum.sort(root: ctx.root, mode: :run, step: :run, nonce: nonce)

    # The run tree places the Instance after the Repo.
    children = apply(@boot, :children, [:run, SdrAgent.Application.children()])
    assert {@instance, :run} in children

    # P3: the boot gate (the test database stands in for the environment's).
    Application.put_env(:sdr_agent, AgentEnv, Keyword.put(agent_env, :database, bound.database))
    assert apply(@instance, :init, [:run]) == :ignore
    assert %{nonce: ^nonce, boot_id: boot_id} = BootFx.boot_binding()

    # P5: an orderly stop of a synthetic top (Fake: no model tree).
    {:ok, top} =
      Supervisor.start_link([%{id: :work, start: {Agent, :start_link, [fn -> :ok end]}}],
        strategy: :one_for_one
      )

    Process.unlink(top)
    on_exit(fn -> if Process.alive?(top), do: Process.exit(top, :kill) end)

    seams = [
      provider: Fake,
      server_name: :"c2star_s1_run_sequence_#{System.unique_integer([:positive])}",
      reaper_lease: fn -> nil end,
      budget_ms: 5_000
    ]

    planned = apply(@shutdown, :plan, [top, seams])
    assert {:ok, %{nonce: ^nonce, boot_id: ^boot_id, root: root}} = planned
    assert root == ctx.root

    :ok = Supervisor.stop(top, :shutdown)
    assert apply(@shutdown, :complete, [planned, seams]) == :ok

    receipt = BootFx.read_object!(BootFx.run_receipt_path(ctx.root, nonce))
    assert {receipt["nonce"], receipt["boot_id"]} == {nonce, boot_id}

    # P5 release, then bound again.
    assert apply(@state, :release, [ctx.root, :run, nonce]) == :ok
    refute File.exists?(Fx.path(ctx.root, :lease))
    assert File.exists?(BootFx.boot_marker_path(ctx.root, nonce))
    assert File.exists?(BootFx.run_receipt_path(ctx.root, nonce))

    facts = {:present, %{database_oid: bound.database_oid, tenant_id: bound.tenant_id}}
    binding = bound.binding_sha256
    assert {:bound, %{sha256: ^binding}} = apply(@state, :classify, [ctx.root, facts])
  end

  test "claude_cli is refused pre-lease: no lease file exists afterwards", ctx do
    Fx.bound!(ctx.root, lease: :none)
    Fx.authorized!(ctx.root)
    require!(@launcher, check: 1)

    inputs = launcher_inputs(ctx, %{"SDR_MODEL_PROVIDER" => "claude_cli"})
    assert apply(@launcher, :check, [inputs]) == {:error, :agent_env_not_spend_ready}
    refute File.exists?(Fx.path(ctx.root, :lease))
  end
end

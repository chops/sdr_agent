defmodule SdrAgent.Scripts.AgentEnvTest do
  @moduledoc """
  C2* S1 PR-B RED-3: the launcher `bin/agent-env` (plan
  `claude-c2star-s1-environment-plan-r2.md` section 5.4; AC2, AC3, AC5; ADR-0004
  agent-environment amendment items 2, 3 and 5; T-V1, shell half).

  The launcher holds checks and sequencing only: no reset, drop, reclaim,
  kill or recovery path, and no state-file write of its own. Its commands
  are `check`, `provision` and `run`; anything else (none, `reset`, `drop`,
  unknown) prints its usage and exits 2.

    * **Shell checks, before any Mix command** (exit 2, naming the item):
      `MIX_ENV` set and not `dev`; `DATABASE_URL` set; `PORT` set and not
      `4130`; the root `$HOME/.local/state/sdr-agent/agent-env/agentenv-1`
      or one of its `build`, `deps`, `state`, `evidence`, `anchors`, `tmp`
      missing, not physical (`cd -P … && pwd -P`) or not 0700;
      `MIX_BUILD_ROOT` and `MIX_DEPS_PATH` unset, not physically under the
      root, or in a `.devenv` directory; `SDR_WITNESS_STORE_ROOT` unset;
      `SDR_ANCHOR_SINKS` not `file`, or `SDR_ANCHOR_FILE_DIR` not physically
      under `<root>/anchors`. For `provision` also `SDR_MODEL_PROVIDER`
      other than unset or `fake`, and `SDR_DEMO_EXCEPTION` set.
    * **Mix calls**, each with `MIX_ENV=dev`, `SDR_AGENT_ENV=agentenv-1`,
      `SDR_AGENT_ENV_STEP` and, once the lease is taken,
      `SDR_AGENT_ENV_NONCE` (read from the task's `SDR_AGENT_ENV_NONCE
      <nonce>` line):
      - `check` → `mix sdr.agent_env check run` (step `check`);
      - `provision` → `check provision`, `preflight`, `lease bootstrap`,
        then `step create|migrate|seed|probe` (step = that step), then
        `publish` and `release bootstrap` (step `check`);
      - `run` → `check run`, `lease run`, then `mix phx.server` with step
        `run` and `PORT=4130`, then `release run`.
      The first non-zero Mix exit stops the sequence (exit 1); a run that
      cannot release states that its lease stays (quarantine). No
      `ecto.*` task is ever called.

  RED: `bin/agent-env` does not exist (structural guard).

  Hermetic: a stub `mix` first on `PATH` records each call (as
  `test/scripts/demo_test.exs`), and a fake `HOME` under
  `tmp/agent-env-roots`; no real Mix, database or port.
  """
  # Spawns the launcher with a modified environment.
  use ExUnit.Case, async: false

  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @script Path.expand("../../bin/agent-env", __DIR__)
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]
  @nonce "0123456789abcdef0123456789abcdef"
  @cleared ~w(MIX_ENV DATABASE_URL PORT SDR_MODEL_PROVIDER SDR_DEMO_EXCEPTION SDR_AGENT_ENV
              SDR_AGENT_ENV_STEP SDR_AGENT_ENV_NONCE PHX_SERVER)

  setup do
    %{home: home, root: root} = BootFx.home!()

    for dir <- @subdirectories do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    bin = Path.join(home, "stub-bin")
    File.mkdir_p!(bin)
    calls = Path.join(home, "mix-calls")
    stub = Path.join(bin, "mix")

    File.write!(stub, """
    #!/bin/sh
    echo "STEP=$SDR_AGENT_ENV_STEP NONCE=$SDR_AGENT_ENV_NONCE PORT=$PORT ENV=$SDR_AGENT_ENV MIX_ENV=$MIX_ENV | $*" >> "#{calls}"
    if [ -n "$STUB_FAIL" ] && [ "$*" = "$STUB_FAIL" ]; then exit 1; fi
    if [ "$1 $2" = "sdr.agent_env lease" ]; then echo "SDR_AGENT_ENV_NONCE #{@nonce}"; fi
    exit 0
    """)

    File.chmod!(stub, 0o755)
    %{home: home, root: root, bin: bin, calls: calls}
  end

  ## Helpers

  defp require_script! do
    assert File.exists?(@script), "C2* S1 RED-3: #{@script} does not exist"
  end

  defp launch(ctx, args, extra \\ []) do
    require_script!()
    System.cmd(@script, args, env: env(ctx, extra), stderr_to_stdout: true)
  end

  defp env(ctx, extra) do
    base = [
      {"HOME", ctx.home},
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"MIX_BUILD_ROOT", Path.join(ctx.root, "build")},
      {"MIX_DEPS_PATH", Path.join(ctx.root, "deps")},
      {"SDR_WITNESS_STORE_ROOT", Path.join(ctx.root, "evidence")},
      {"SDR_ANCHOR_SINKS", "file"},
      {"SDR_ANCHOR_FILE_DIR", Path.join(ctx.root, "anchors")},
      {"STUB_FAIL", nil}
    ]

    cleared = Enum.map(@cleared, &{&1, nil})
    overridden = Map.new(extra)

    (cleared ++ base)
    |> Enum.reject(fn {name, _value} -> Map.has_key?(overridden, name) end)
    |> Kernel.++(extra)
  end

  defp calls(ctx) do
    case File.read(ctx.calls) do
      {:ok, calls} -> String.split(calls, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp call(step, nonce, args, port \\ ""),
    do: "STEP=#{step} NONCE=#{nonce} PORT=#{port} ENV=agentenv-1 MIX_ENV=dev | #{args}"

  @provision [
    {"check", "", "sdr.agent_env check provision"},
    {"check", "", "sdr.agent_env preflight"},
    {"check", "", "sdr.agent_env lease bootstrap"},
    {"create", @nonce, "sdr.agent_env step create"},
    {"migrate", @nonce, "sdr.agent_env step migrate"},
    {"seed", @nonce, "sdr.agent_env step seed"},
    {"probe", @nonce, "sdr.agent_env step probe"},
    {"check", @nonce, "sdr.agent_env publish"},
    {"check", @nonce, "sdr.agent_env release bootstrap"}
  ]

  defp provision_calls,
    do: Enum.map(@provision, fn {step, nonce, args} -> call(step, nonce, args) end)

  ## Usage and the command set

  describe "the command set" do
    test "no command, reset, drop or an unknown command prints the usage with no Mix call", ctx do
      for args <- [
            [],
            ["reset"],
            ["drop"],
            ["recover"],
            ["kill"],
            ["provision", "extra"],
            ["bogus"]
          ] do
        assert {out, 2} = launch(ctx, args), inspect(args)
        assert out =~ ~r/usage/i, inspect(args)
      end

      assert calls(ctx) == []
    end

    test "the script is executable and parses (bash -n)" do
      require_script!()
      %File.Stat{mode: mode} = File.stat!(@script)
      assert Bitwise.band(mode, 0o111) == 0o111
      assert {_out, 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
    end
  end

  ## Refusals before any Mix command

  describe "refusals before any Mix command" do
    test "MIX_ENV other than dev, DATABASE_URL and a PORT other than 4130", ctx do
      for {extra, item} <- [
            {[{"MIX_ENV", "prod"}], "MIX_ENV"},
            {[{"MIX_ENV", "test"}], "MIX_ENV"},
            {[{"DATABASE_URL", "ecto://synthetic:synthetic@elsewhere.invalid/other"}],
             "DATABASE_URL"},
            {[{"PORT", "4120"}], "PORT"},
            {[{"PORT", "4122"}], "PORT"},
            {[{"PORT", "4002"}], "PORT"}
          ],
          command <- ["check", "provision", "run"] do
        assert {out, 2} = launch(ctx, [command], extra), inspect({command, extra})
        assert out =~ item, inspect({command, extra})
      end

      assert calls(ctx) == []
    end

    test "a missing, symlinked or group-accessible root or subdirectory", ctx do
      for {arrange, restore} <- [
            {fn -> File.chmod!(ctx.root, 0o750) end, fn -> File.chmod!(ctx.root, 0o700) end},
            {fn -> File.chmod!(Path.join(ctx.root, "state"), 0o755) end,
             fn -> File.chmod!(Path.join(ctx.root, "state"), 0o700) end},
            {fn -> File.rm_rf!(Path.join(ctx.root, "tmp")) end,
             fn ->
               File.mkdir_p!(Path.join(ctx.root, "tmp"))
               File.chmod!(Path.join(ctx.root, "tmp"), 0o700)
             end},
            {fn ->
               File.rm_rf!(Path.join(ctx.root, "evidence"))
               :ok = File.ln_s(Fx.root!("elsewhere"), Path.join(ctx.root, "evidence"))
             end,
             fn ->
               File.rm!(Path.join(ctx.root, "evidence"))
               File.mkdir_p!(Path.join(ctx.root, "evidence"))
               File.chmod!(Path.join(ctx.root, "evidence"), 0o700)
             end}
          ] do
        arrange.()
        assert {out, 2} = launch(ctx, ["check"])
        assert out =~ "root"
        restore.()
      end

      assert calls(ctx) == []
    end

    test "a root that is itself a symlink, or absent", ctx do
      parent = Path.dirname(ctx.root)
      real = Path.join(parent, "agentenv-1-real")
      File.rename!(ctx.root, real)
      :ok = File.ln_s(real, ctx.root)

      assert {out, 2} = launch(ctx, ["check"])
      assert out =~ "root"

      File.rm!(ctx.root)
      assert {out, 2} = launch(ctx, ["check"])
      assert out =~ "root"
      assert calls(ctx) == []
    end

    test "Mix build and deps paths not physically under the root", ctx do
      outside = Fx.root!("outside")
      devenv = Path.join([ctx.root, "build", ".devenv"])
      File.mkdir_p!(devenv)

      for {extra, item} <- [
            {[{"MIX_BUILD_ROOT", nil}], "MIX_BUILD_ROOT"},
            {[{"MIX_BUILD_ROOT", outside}], "MIX_BUILD_ROOT"},
            {[{"MIX_BUILD_ROOT", devenv}], "MIX_BUILD_ROOT"},
            {[{"MIX_BUILD_ROOT", Path.expand(".devenv/state/build")}], "MIX_BUILD_ROOT"},
            {[{"MIX_DEPS_PATH", nil}], "MIX_DEPS_PATH"},
            {[{"MIX_DEPS_PATH", outside}], "MIX_DEPS_PATH"}
          ] do
        assert {out, 2} = launch(ctx, ["check"], extra), inspect(extra)
        assert out =~ item, inspect(extra)
      end

      assert calls(ctx) == []
    end

    test "the witness root and the anchor sinks", ctx do
      outside = Fx.root!("anchors-outside")

      for {extra, item} <- [
            {[{"SDR_WITNESS_STORE_ROOT", nil}], "SDR_WITNESS_STORE_ROOT"},
            {[{"SDR_WITNESS_STORE_ROOT", ""}], "SDR_WITNESS_STORE_ROOT"},
            {[{"SDR_ANCHOR_SINKS", nil}], "SDR_ANCHOR_SINKS"},
            {[{"SDR_ANCHOR_SINKS", "git+ots"}], "SDR_ANCHOR_SINKS"},
            {[{"SDR_ANCHOR_FILE_DIR", nil}], "SDR_ANCHOR_FILE_DIR"},
            {[{"SDR_ANCHOR_FILE_DIR", outside}], "SDR_ANCHOR_FILE_DIR"},
            {[{"SDR_ANCHOR_FILE_DIR", Path.join(ctx.root, "state")}], "SDR_ANCHOR_FILE_DIR"}
          ] do
        assert {out, 2} = launch(ctx, ["run"], extra), inspect(extra)
        assert out =~ item, inspect(extra)
      end

      assert calls(ctx) == []
    end

    test "provision refuses a real provider and any demo exception", ctx do
      for {extra, item} <- [
            {[{"SDR_MODEL_PROVIDER", "claude_cli"}], "SDR_MODEL_PROVIDER"},
            {[{"SDR_MODEL_PROVIDER", "bogus"}], "SDR_MODEL_PROVIDER"},
            {[{"SDR_DEMO_EXCEPTION", "c2star-demo-v4/1"}], "SDR_DEMO_EXCEPTION"},
            {[{"SDR_DEMO_EXCEPTION", ""}], "SDR_DEMO_EXCEPTION"}
          ] do
        assert {out, 2} = launch(ctx, ["provision"], extra), inspect(extra)
        assert out =~ item, inspect(extra)
      end

      assert calls(ctx) == []
    end
  end

  ## Sequencing

  describe "sequencing" do
    test "check runs the run-intent check only", ctx do
      assert {_out, 0} = launch(ctx, ["check"])
      assert calls(ctx) == [call("check", "", "sdr.agent_env check run")]
    end

    test "provision runs every step in order under the lease's nonce", ctx do
      for extra <- [
            [],
            [{"SDR_MODEL_PROVIDER", "fake"}],
            [{"MIX_ENV", "dev"}],
            [{"PORT", "4130"}]
          ] do
        File.rm_rf!(ctx.calls)
        assert {_out, 0} = launch(ctx, ["provision"], extra), inspect(extra)

        expected =
          if Map.new(extra)["PORT"] == "4130",
            do: Enum.map(provision_calls(), &String.replace(&1, "PORT= ", "PORT=4130 ")),
            else: provision_calls()

        assert calls(ctx) == expected, inspect(extra)
      end

      assert BootFx.state_files(ctx.root) == [], "C2* S1: the launcher writes no state file"
    end

    test "the first failing Mix call stops the sequence with a non-zero exit", ctx do
      assert {_out, 1} = launch(ctx, ["provision"], [{"STUB_FAIL", "sdr.agent_env step migrate"}])
      assert calls(ctx) == Enum.take(provision_calls(), 5)
    end

    test "run checks, takes the run lease, serves on 4130 and releases", ctx do
      assert {_out, 0} = launch(ctx, ["run"])

      assert calls(ctx) == [
               call("check", "", "sdr.agent_env check run"),
               call("check", "", "sdr.agent_env lease run"),
               call("run", @nonce, "phx.server", "4130"),
               call("check", @nonce, "sdr.agent_env release run")
             ]
    end

    test "a run that cannot release exits non-zero and says its lease stays", ctx do
      assert {out, 1} = launch(ctx, ["run"], [{"STUB_FAIL", "sdr.agent_env release run"}])
      assert out =~ ~r/lease/i
      assert out =~ ~r/quarantin|stale/i
    end

    test "a lease line without a nonce stops before any step", ctx do
      stub = Path.join(ctx.bin, "mix")

      File.write!(stub, """
      #!/bin/sh
      echo "$*" >> "#{ctx.calls}"
      exit 0
      """)

      assert {_out, 1} = launch(ctx, ["run"])
      assert calls(ctx) == ["sdr.agent_env check run", "sdr.agent_env lease run"]
    end

    test "no ecto task is ever called", ctx do
      for command <- ["check", "provision", "run"] do
        launch(ctx, [command])
      end

      refute Enum.any?(calls(ctx), &(&1 =~ ~r/\| ecto\./))
    end
  end
end

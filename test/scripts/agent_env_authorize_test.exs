defmodule SdrAgent.Scripts.AgentEnvAuthorizeTest do
  @moduledoc """
  C2* S2 RED-3 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §5
  "`bin/agent-env authorize`" and §7 row "test/scripts/agent_env_authorize_test.exs";
  Codex plan/entity PASS `aa42492e`, OQ13/OQ14; AC9): the launcher's
  `authorize` command, the shell half.

  `bin/agent-env authorize` runs the S1 shell checks (AC2 subset) plus
  `SDR_MODEL_PROVIDER` unset or `fake` and no `SDR_DEMO_EXCEPTION`, and then
  exactly six Mix calls, stopping at the first non-zero exit (exit 1, no
  later call), each with `MIX_ENV=dev` and `SDR_AGENT_ENV=agentenv-1`:

    1. `mix sdr.agent_env authorize-check` (step `check`, no nonce);
    2. `mix sdr.agent_env claim` (step `check`, no nonce);
    3. `mix sdr.agent_env lease provisioning` (step `check`; prints the
       `SDR_AGENT_ENV_NONCE <nonce>` line);
    4. `mix sdr.agent_env step provision` (step `provision`, the nonce);
    5. `mix sdr.agent_env release provisioning` (step `check`, the nonce);
    6. `mix sdr.agent_env finalize` (step `check`, the nonce).

  There is no repair, reset or retry. Any other argument after `authorize`
  is a usage error with no Mix call.

  RED: `bin/agent-env` (S1) has no `authorize` command; it answers with
  its usage (exit 2) and makes no Mix call, so every sequencing test fails
  its assertion (behavioural, against the shipped S1 launcher), and each
  refusal test fails on the missing item name in the output. `bash -n` and
  the stub control pass.

  Hermetic, as `test/scripts/agent_env_test.exs` (S1): a stub `mix` first on
  `PATH` records each call; a fake `HOME` under `tmp/agent-env-roots`; no
  real Mix, database, port or model.
  """
  # Spawns the launcher with a modified environment.
  use ExUnit.Case, async: false

  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx

  @moduletag :c2star_s2

  @script Path.expand("../../bin/agent-env", __DIR__)
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]
  @nonce "0123456789abcdef0123456789abcdef"
  @cleared ~w(MIX_ENV DATABASE_URL PORT SDR_MODEL_PROVIDER SDR_DEMO_EXCEPTION SDR_AGENT_ENV
              SDR_AGENT_ENV_STEP SDR_AGENT_ENV_NONCE PHX_SERVER)

  # The six calls of `authorize`, in order: {step, nonce, arguments}.
  @authorize [
    {"check", "", "sdr.agent_env authorize-check"},
    {"check", "", "sdr.agent_env claim"},
    {"check", "", "sdr.agent_env lease provisioning"},
    {"provision", @nonce, "sdr.agent_env step provision"},
    {"check", @nonce, "sdr.agent_env release provisioning"},
    {"check", @nonce, "sdr.agent_env finalize"}
  ]

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

    # Each call is recorded; `STUB_FAIL` names the one call that exits 1; a
    # lease call prints the nonce line.
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
    assert File.exists?(@script), "c2star-s2: #{@script} does not exist"
  end

  defp launch(ctx, args, extra \\ []) do
    require_script!()
    System.cmd(@script, args, env: env(ctx, extra), stderr_to_stdout: true)
  end

  # `name` set but empty, through /usr/bin/env (System.cmd's `env:` unsets a
  # variable given "").
  defp launch_empty(ctx, args, name) do
    require_script!()

    System.cmd("/usr/bin/env", ["#{name}=", @script | args],
      env: env(ctx, [{name, nil}]),
      stderr_to_stdout: true
    )
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

  defp call(step, nonce, args),
    do: "STEP=#{step} NONCE=#{nonce} PORT= ENV=agentenv-1 MIX_ENV=dev | #{args}"

  defp authorize_calls,
    do: Enum.map(@authorize, fn {step, nonce, args} -> call(step, nonce, args) end)

  ## Control

  describe "fixtures" do
    test "control: the stub mix records a call and prints the nonce for a lease", ctx do
      stub = Path.join(ctx.bin, "mix")
      env = [{"SDR_AGENT_ENV_STEP", "check"}, {"SDR_AGENT_ENV", "agentenv-1"}, {"MIX_ENV", "dev"}]

      assert System.cmd(stub, ["sdr.agent_env", "lease", "provisioning"], env: env) ==
               {"SDR_AGENT_ENV_NONCE #{@nonce}\n", 0}

      assert calls(ctx) == [call("check", "", "sdr.agent_env lease provisioning")]
    end

    test "control: the script is executable and parses (bash -n)" do
      require_script!()
      %File.Stat{mode: mode} = File.stat!(@script)
      assert Bitwise.band(mode, 0o111) == 0o111
      assert {_out, 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
    end
  end

  ## The command

  describe "sequencing" do
    test "authorize makes the six calls in order under the provisioning lease's nonce", ctx do
      for extra <- [[], [{"SDR_MODEL_PROVIDER", "fake"}], [{"MIX_ENV", "dev"}]] do
        File.rm_rf!(ctx.calls)
        result = launch(ctx, ["authorize"], extra)

        assert match?({_out, 0}, result),
               "c2star-s2: authorize #{inspect(extra)}: #{inspect(result)}"

        assert calls(ctx) == authorize_calls(), inspect(extra)
      end

      assert BootFx.state_files(ctx.root) == [],
             "c2star-s2: the launcher writes no state file of its own"
    end

    test "a failure at any of the six calls stops there with exit 1 and no later call", ctx do
      for {{_step, _nonce, args}, index} <- Enum.with_index(@authorize) do
        File.rm_rf!(ctx.calls)
        result = launch(ctx, ["authorize"], [{"STUB_FAIL", args}])
        assert match?({_out, 1}, result), "c2star-s2: failing #{args}: #{inspect(result)}"
        assert calls(ctx) == Enum.take(authorize_calls(), index + 1), args
      end
    end

    test "authorize with an extra argument prints the usage with no Mix call", ctx do
      for args <- [["authorize", "extra"], ["authorize", "check"]] do
        assert {out, 2} = launch(ctx, args), inspect(args)
        assert out =~ ~r/usage/i, inspect(args)
      end

      assert calls(ctx) == []
    end

    test "the usage names the authorize command", ctx do
      assert {out, 2} = launch(ctx, ["bogus"])

      assert out =~ "authorize",
             "c2star-s2: the usage does not name authorize: #{inspect(out)}"
    end
  end

  describe "refusals before any Mix command" do
    test "authorize refuses a real provider and any demo exception", ctx do
      for {extra, item} <- [
            {[{"SDR_MODEL_PROVIDER", "claude_cli"}], "SDR_MODEL_PROVIDER"},
            {[{"SDR_MODEL_PROVIDER", "bogus"}], "SDR_MODEL_PROVIDER"},
            {[{"SDR_DEMO_EXCEPTION", "c2star-demo-v4/1"}], "SDR_DEMO_EXCEPTION"}
          ] do
        result = launch(ctx, ["authorize"], extra)
        assert match?({_out, 2}, result), inspect({extra, result})
        {out, 2} = result
        assert out =~ item, "c2star-s2: #{item} not named: #{inspect(out)}"
      end

      result = launch_empty(ctx, ["authorize"], "SDR_DEMO_EXCEPTION")
      assert match?({_out, 2}, result), inspect(result)
      assert elem(result, 0) =~ "SDR_DEMO_EXCEPTION"

      assert calls(ctx) == []
    end

    test "authorize applies the S1 shell checks: MIX_ENV, DATABASE_URL and PORT", ctx do
      for {extra, item} <- [
            {[{"MIX_ENV", "prod"}], "MIX_ENV"},
            {[{"DATABASE_URL", "ecto://synthetic:synthetic@elsewhere.invalid/other"}],
             "DATABASE_URL"},
            {[{"PORT", "4120"}], "PORT"}
          ] do
        result = launch(ctx, ["authorize"], extra)
        assert match?({_out, 2}, result), inspect({extra, result})
        assert elem(result, 0) =~ item, "c2star-s2: #{item} not named: #{inspect(result)}"
      end

      assert calls(ctx) == []
    end
  end
end

defmodule SdrAgent.Scripts.CalibrationConsoleTest do
  @moduledoc """
  Tests for `bin/calibration-console` (R0-07 §3, §4 "Calibration console"):
  the reviewed entry point that serves the test-seam build from the fixed,
  persistent `sdr_agent_calibration` database so the owner can sign in and
  create the single G-R0 grant.

  The guard tests put a stub `mix` first on `PATH` that records its
  arguments and the environment it was started with, and answers the
  console's `check` with a configurable plan line (`STUB_PLAN_LINE`), so
  every refusal is proven to happen before the console starts anything.
  One test runs the real `mix sdr.calibration.console check`, which reads
  the configuration the console would serve with and touches no database.
  No test creates, migrates, serves or drops `sdr_agent_calibration`.
  """
  # Spawns shell and Mix processes; one test holds 127.0.0.1:4124 while the
  # others check that it is free, so they never run concurrently.
  use ExUnit.Case, async: false

  @script Path.expand("../../bin/calibration-console", __DIR__)
  @task_source Path.expand("../../lib/mix/tasks/sdr.calibration.console.ex", __DIR__)
  @module_source Path.expand("../../lib/sdr_agent/calibration_console.ex", __DIR__)
  @good_plan "SDR_CALIBRATION_CONSOLE sdr_agent_calibration localhost 5520 127.0.0.1 4124 " <>
               "SdrAgent.AI.ModelProvider.Fake none"
  @moduletag timeout: 300_000

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "calibration-console-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "bin"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    stub = Path.join(tmp, "bin/mix")

    File.write!(stub, """
    #!/bin/sh
    echo "$*" >> "#{tmp}/mix-calls"
    echo "MIX_ENV=${MIX_ENV-unset} SDR_MODEL_PROVIDER=${SDR_MODEL_PROVIDER-unset} \
    SDR_CLAUDE_CLI_BIN=${SDR_CLAUDE_CLI_BIN-unset} PORT=${PORT-unset} \
    DATABASE_URL=${DATABASE_URL-unset}" >> "#{tmp}/mix-env"
    if [ "$2" = check ]; then echo "$STUB_PLAN_LINE"; fi
    exit 0
    """)

    File.chmod!(stub, 0o755)

    %{
      tmp: tmp,
      stub_path: Path.join(tmp, "bin") <> ":" <> System.get_env("PATH"),
      calls: Path.join(tmp, "mix-calls"),
      envs: Path.join(tmp, "mix-env")
    }
  end

  defp console(args, env), do: System.cmd(@script, args, env: env, stderr_to_stdout: true)

  defp stubbed(ctx, extra \\ []) do
    [
      {"PATH", ctx.stub_path},
      {"MIX_ENV", nil},
      {"DATABASE_URL", nil},
      {"PORT", nil},
      {"SDR_MODEL_PROVIDER", nil},
      {"SDR_CLAUDE_CLI_BIN", nil},
      {"STUB_PLAN_LINE", @good_plan}
    ]
    |> then(&Enum.reduce(extra, &1, fn {k, _} = kv, env -> List.keystore(env, k, 0, kv) end))
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp mix_calls(ctx), do: lines(ctx.calls)
  defp mix_envs(ctx), do: lines(ctx.envs)

  defp plan_line(fields) do
    defaults = [
      database: "sdr_agent_calibration",
      host: "localhost",
      db_port: "5520",
      ip: "127.0.0.1",
      port: "4124",
      provider: "SdrAgent.AI.ModelProvider.Fake",
      model_server: "none"
    ]

    values = Keyword.merge(defaults, fields)

    Enum.join(
      ["SDR_CALIBRATION_CONSOLE" | Enum.map(Keyword.keys(defaults), &values[&1])],
      " "
    )
  end

  describe "the database: only sdr_agent_calibration" do
    for url <- [
          "ecto://postgres:postgres@localhost:5520/sdr_agent_dev",
          "ecto://postgres:postgres@localhost:5520/sdr_agent_test",
          "ecto://postgres:postgres@localhost:5520/sdr_agent_test_r07d",
          "ecto://u:p@db.example.test/anything",
          "ecto://postgres:postgres@localhost:5520/sdr_agent_calibration"
        ] do
      test "refuses any DATABASE_URL (#{url})", ctx do
        assert {out, 2} = console(["serve"], stubbed(ctx, [{"DATABASE_URL", unquote(url)}]))
        assert out =~ "DATABASE_URL is set"
        refute out =~ "postgres:postgres@"
        refute out =~ "u:p@"
        assert mix_calls(ctx) == []
      end
    end

    for database <- [
          "sdr_agent_dev",
          "sdr_agent_test",
          "sdr_agent_test_r07d",
          "sdr_agent_test_demo",
          "sdr_agent_calibration_demo",
          "sdr_agent_calibration2",
          "postgres"
        ] do
      test "refuses an effective database #{database}", ctx do
        env = stubbed(ctx, [{"STUB_PLAN_LINE", plan_line(database: unquote(database))}])
        assert {out, 2} = console(["serve"], env)
        assert out =~ "database #{unquote(database)} is not sdr_agent_calibration"
        assert mix_calls(ctx) == ["sdr.calibration.console check"]
      end
    end

    test "refuses a database host that is not local", ctx do
      env = stubbed(ctx, [{"STUB_PLAN_LINE", plan_line(host: "db.example.test")}])
      assert {out, 2} = console(["serve"], env)
      assert out =~ "database host db.example.test is not local"
      assert mix_calls(ctx) == ["sdr.calibration.console check"]
    end

    test "refuses a database port that is not the devenv Postgres 5520", ctx do
      env = stubbed(ctx, [{"STUB_PLAN_LINE", plan_line(db_port: "5432")}])
      assert {out, 2} = console(["serve"], env)
      assert out =~ "database port 5432 is not the devenv Postgres port 5520"
      assert mix_calls(ctx) == ["sdr.calibration.console check"]
    end

    test "refuses when the console's plan cannot be read", ctx do
      env = stubbed(ctx, [{"STUB_PLAN_LINE", "garbage"}])
      assert {out, 2} = console(["serve"], env)
      assert out =~ "could not read the calibration console plan"
      assert mix_calls(ctx) == ["sdr.calibration.console check"]
    end

    test "accepts sdr_agent_calibration and serves it", ctx do
      assert {out, 0} = console(["serve"], stubbed(ctx))
      assert out =~ "sdr_agent_calibration"
      assert mix_calls(ctx) == ["sdr.calibration.console check", "sdr.calibration.console serve"]
    end

    test "check prints the plan and starts nothing", ctx do
      assert {out, 0} = console(["check"], stubbed(ctx, [{"HOME", ctx.tmp}]))
      assert out =~ "secrets #{ctx.tmp}/.local/state/sdr-agent/calibration/secrets"
      assert out =~ "database sdr_agent_calibration on localhost:5520"
      assert out =~ "http://127.0.0.1:4124"
      assert mix_calls(ctx) == ["sdr.calibration.console check"]
    end
  end

  describe "the test-seam build only" do
    for env <- ["dev", "prod"] do
      test "refuses MIX_ENV=#{env}", ctx do
        assert {out, 2} = console(["serve"], stubbed(ctx, [{"MIX_ENV", unquote(env)}]))
        assert out =~ "MIX_ENV=#{unquote(env)} is not the test-seam build (test)"
        assert mix_calls(ctx) == []
      end
    end

    test "runs Mix with MIX_ENV=test", ctx do
      assert {_out, 0} = console(["serve"], stubbed(ctx))
      assert Enum.all?(mix_envs(ctx), &String.starts_with?(&1, "MIX_ENV=test "))
    end
  end

  describe "loopback 127.0.0.1:4124 only" do
    for port <- ["4120", "4122", "4000", "0", "80", "abc"] do
      test "refuses PORT=#{port}", ctx do
        assert {out, 2} = console(["serve"], stubbed(ctx, [{"PORT", unquote(port)}]))
        assert out =~ "PORT=#{unquote(port)}: the calibration console listens only on 4124"
        assert mix_calls(ctx) == []
      end
    end

    test "PORT=4124 is accepted and Mix never sees PORT", ctx do
      assert {_out, 0} = console(["serve"], stubbed(ctx, [{"PORT", "4124"}]))
      assert length(mix_envs(ctx)) == 2
      assert Enum.all?(mix_envs(ctx), &(&1 =~ "PORT=unset"))
    end

    for {field, value, reason} <- [
          {:ip, "0.0.0.0", "bind address 0.0.0.0:4124 is not 127.0.0.1:4124"},
          {:ip, "::", "bind address :::4124 is not 127.0.0.1:4124"},
          {:port, "4120", "bind address 127.0.0.1:4120 is not 127.0.0.1:4124"}
        ] do
      test "refuses a plan that binds #{value}", ctx do
        env = stubbed(ctx, [{"STUB_PLAN_LINE", plan_line([{unquote(field), unquote(value)}])}])
        assert {out, 2} = console(["serve"], env)
        assert out =~ unquote(reason)
        assert mix_calls(ctx) == ["sdr.calibration.console check"]
      end
    end

    test "refuses when 4124 is already in use", ctx do
      case :gen_tcp.listen(4124, ip: {127, 0, 0, 1}, active: false, reuseaddr: true) do
        {:ok, socket} ->
          on_exit(fn -> :gen_tcp.close(socket) end)
          assert {out, 2} = console(["serve"], stubbed(ctx))
          assert out =~ "port 4124 is already in use"
          assert mix_calls(ctx) == []

        {:error, :eaddrinuse} ->
          # Something (perhaps the owner's console) already holds it.
          assert {out, 2} = console(["serve"], stubbed(ctx))
          assert out =~ "port 4124 is already in use"
          assert mix_calls(ctx) == []
      end
    end
  end

  describe "no model server" do
    for provider <- ["claude_cli", "anything"] do
      test "refuses SDR_MODEL_PROVIDER=#{provider}", ctx do
        env = stubbed(ctx, [{"SDR_MODEL_PROVIDER", unquote(provider)}])
        assert {out, 2} = console(["serve"], env)
        assert out =~ "SDR_MODEL_PROVIDER=#{unquote(provider)}: the calibration console runs"
        assert mix_calls(ctx) == []
      end
    end

    test "Mix runs with the Fake selected and no pinned CLI path", ctx do
      env = stubbed(ctx, [{"SDR_MODEL_PROVIDER", "fake"}, {"SDR_CLAUDE_CLI_BIN", "/nix/store/x"}])
      assert {_out, 0} = console(["serve"], env)
      assert [_check, _serve] = mix_envs(ctx)

      for line <- mix_envs(ctx) do
        assert line =~ "SDR_MODEL_PROVIDER=fake "
        assert line =~ "SDR_CLAUDE_CLI_BIN=unset "
      end
    end

    for {provider, server} <- [
          {"SdrAgent.AI.ModelProvider.ClaudeCLI", "none"},
          {"SdrAgent.AI.ModelProvider.Fake", "SdrAgent.AI.ModelProvider.ClaudeCLI"}
        ] do
      test "refuses a plan with provider #{provider} and model server #{server}", ctx do
        line = plan_line(provider: unquote(provider), model_server: unquote(server))
        assert {out, 2} = console(["serve"], stubbed(ctx, [{"STUB_PLAN_LINE", line}]))
        assert out =~ "the calibration console starts no model server"
        assert mix_calls(ctx) == ["sdr.calibration.console check"]
      end
    end
  end

  describe "no reset, drop or seed path" do
    for command <- ["reset", "drop", "seed", "run", "migrate", "predeliver"] do
      test "#{command} is not a command", ctx do
        assert {out, 2} = console([unquote(command)], stubbed(ctx))
        assert out =~ "usage: bin/calibration-console"
        assert mix_calls(ctx) == []
      end
    end

    test "the usage discloses that check and serve initialize the secrets file", ctx do
      assert {out, 2} = console(["--help"], stubbed(ctx))
      assert out =~ "~/.local/state/sdr-agent/calibration/secrets"
      assert out =~ "creates"
    end

    # R0-07 d3c (packet 8.14.1): calibrate takes exactly one profile and
    # passes it to the task unchanged; the guards above still run first.
    test "calibrate passes exactly its one profile to the task", ctx do
      assert {_out, 0} = console(["calibrate", "claude_cli_opus"], stubbed(ctx))

      assert mix_calls(ctx) == [
               "sdr.calibration.console check",
               "sdr.calibration.console calibrate claude_cli_opus"
             ]
    end

    test "calibrate without a profile, or with more, is refused", ctx do
      assert {out, 2} = console(["calibrate"], stubbed(ctx))
      assert out =~ "usage: bin/calibration-console"
      assert {_out, 2} = console(["calibrate", "claude_cli_opus", "--yes"], stubbed(ctx))
      assert mix_calls(ctx) == []
    end

    # R0-07 d3d (packet 8.14.11): calibrate-recover forwards its one or two
    # arguments unchanged; the task's recover_command/1 decides the rest.
    test "calibrate-recover passes its arguments to the task unchanged", ctx do
      id = Ash.UUIDv7.generate()
      assert {_out, 0} = console(["calibrate-recover", id], stubbed(ctx))

      assert {_out, 0} =
               console(["calibrate-recover", id, "--owner-verified-stopped"], stubbed(ctx))

      assert {_out, 0} = console(["calibrate-recover", "--release-aborted"], stubbed(ctx))

      assert mix_calls(ctx) == [
               "sdr.calibration.console check",
               "sdr.calibration.console calibrate-recover #{id}",
               "sdr.calibration.console check",
               "sdr.calibration.console calibrate-recover #{id} --owner-verified-stopped",
               "sdr.calibration.console check",
               "sdr.calibration.console calibrate-recover --release-aborted"
             ]
    end

    test "calibrate-recover without arguments, or with more than two, is refused", ctx do
      assert {out, 2} = console(["calibrate-recover"], stubbed(ctx))
      assert out =~ "calibrate-recover"
      assert {_out, 2} = console(["calibrate-recover", "a", "b", "c"], stubbed(ctx))
      assert mix_calls(ctx) == []
    end

    test "no command, or extra arguments to serve, is refused", ctx do
      assert {_out, 2} = console([], stubbed(ctx))
      assert {_out, 2} = console(["serve", "--yes"], stubbed(ctx))
      assert {_out, 2} = console(["check", "reset"], stubbed(ctx))
      assert mix_calls(ctx) == []
    end

    test "the script, the task and the console module name no destructive operation" do
      for path <- [@script, @task_source, @module_source] do
        source = File.read!(path)

        for forbidden <- [
              "ecto.drop",
              "ecto.reset",
              "ash.reset",
              "storage_down",
              "DROP DATABASE",
              "TRUNCATE",
              "sdr.demo.seed",
              "seeds.exs",
              "Demo.Seed",
              "--force-drop"
            ] do
          refute source =~ forbidden, "#{Path.basename(path)} mentions #{forbidden}"
        end
      end
    end

    test "the script never reuses bin/demo or the demo serve task" do
      source = File.read!(@script)
      refute source =~ "bin/demo"
      refute source =~ "sdr.demo."
      refute File.read!(@task_source) =~ "Sdr.Demo.Serve"
    end
  end

  describe "bootstrap-admin" do
    test "passes its arguments to the console's bootstrap after the same checks", ctx do
      args = ["bootstrap-admin", "--email", "owner@example.test", "--password-stdin"]
      assert {_out, 0} = console(args, stubbed(ctx))

      assert mix_calls(ctx) == [
               "sdr.calibration.console check",
               "sdr.calibration.console bootstrap-admin --email owner@example.test --password-stdin"
             ]
    end

    test "is refused against another database", ctx do
      env = stubbed(ctx, [{"STUB_PLAN_LINE", plan_line(database: "sdr_agent_dev")}])
      assert {out, 2} = console(["bootstrap-admin", "--password-stdin"], env)
      assert out =~ "database sdr_agent_dev is not sdr_agent_calibration"
      assert mix_calls(ctx) == ["sdr.calibration.console check"]
    end
  end

  describe "the real console's per-machine secrets (temporary HOME, no database)" do
    setup do
      home =
        Path.join(System.tmp_dir!(), "calibration-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      {physical, 0} = System.cmd("pwd", ["-P"], cd: home)
      %{home: String.trim(physical)}
    end

    defp real_check(home) do
      env = [
        {"HOME", home},
        {"MIX_ENV", nil},
        {"PORT", nil},
        {"DATABASE_URL", nil},
        {"SDR_MODEL_PROVIDER", nil},
        {"SDR_CLAUDE_CLI_BIN", nil}
      ]

      System.cmd(@script, ["check"], env: env, stderr_to_stdout: true)
    end

    test "are created 0600 in a 0700 directory, never printed, and reused", %{home: home} do
      dir = Path.join(home, ".local/state/sdr-agent/calibration")
      path = Path.join(dir, "secrets")

      assert {out, 0} = real_check(home)
      assert out =~ "database sdr_agent_calibration"
      # check discloses that it initializes the secrets file (path only).
      assert out =~ "secrets #{path} (created on first use"
      assert Bitwise.band(File.lstat!(dir).mode, 0o777) == 0o700
      assert Bitwise.band(File.lstat!(path).mode, 0o777) == 0o600

      body = File.read!(path)

      values =
        for line <- String.split(body, "\n", trim: true),
            do: line |> String.split("=", parts: 2) |> List.last()

      assert length(values) == 2
      for value <- values, do: refute(out =~ value)

      assert {again, 0} = real_check(home)
      assert File.read!(path) == body
      for value <- values, do: refute(again =~ value)
    end

    test "a group-readable secrets file is refused", %{home: home} do
      path = Path.join(home, ".local/state/sdr-agent/calibration/secrets")
      assert {_out, 0} = real_check(home)
      File.chmod!(path, 0o640)
      assert {out, status} = real_check(home)
      assert status != 0
      assert out =~ "readable or writable by group or others"
    end
  end

  describe "the real check (configuration only, no database)" do
    test "serves sdr_agent_calibration on 127.0.0.1:4124 with the Fake, whatever the partition and PORT" do
      # A temporary HOME: the check creates the per-machine secrets file.
      home =
        Path.join(System.tmp_dir!(), "calibration-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)

      env = [
        {"HOME", home},
        {"MIX_ENV", "test"},
        {"MIX_TEST_PARTITION", "_r07d_probe"},
        {"PORT", "4120"},
        {"DATABASE_URL", nil},
        {"SDR_MODEL_PROVIDER", nil},
        {"SDR_CLAUDE_CLI_BIN", nil}
      ]

      assert {out, 0} =
               System.cmd("mix", ["sdr.calibration.console", "check"],
                 env: env,
                 stderr_to_stdout: true
               )

      assert [line] =
               out |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^SDR_CALIBRATION_CONSOLE /))

      assert line ==
               "SDR_CALIBRATION_CONSOLE sdr_agent_calibration localhost 5520 127.0.0.1 4124 " <>
                 "SdrAgent.AI.ModelProvider.Fake none"
    end
  end
end

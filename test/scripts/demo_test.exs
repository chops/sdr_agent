defmodule SdrAgent.Scripts.DemoTest do
  @moduledoc """
  Tests for `bin/demo` (S13; checklist 4.1). The guard tests put a stub
  `mix` first on PATH that records its arguments, so a refusal is proven to
  happen before any Mix command runs. The end-to-end test drives the real
  `mix` in `--test` mode, which targets its own throw-away database
  (`sdr_agent_test<partition>_demo`), never the suite's or the dev database.
  """
  # Spawns Mix processes that create and drop a database.
  use ExUnit.Case, async: false

  alias SdrAgent.Demo.Fixtures

  @script Path.expand("../../bin/demo", __DIR__)
  @moduletag timeout: 600_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "bin-demo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "bin"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    stub = Path.join(tmp, "bin/mix")

    File.write!(stub, """
    #!/bin/sh
    echo "$*" >> "#{tmp}/mix-calls"
    if [ "$1" = run ]; then echo "$STUB_REPO_LINE"; fi
    exit 0
    """)

    File.chmod!(stub, 0o755)

    %{
      tmp: tmp,
      stub_path: Path.join(tmp, "bin") <> ":" <> System.get_env("PATH"),
      calls: Path.join(tmp, "mix-calls")
    }
  end

  defp demo(args, env), do: System.cmd(@script, args, env: env, stderr_to_stdout: true)

  defp stubbed(ctx, extra \\ []) do
    [{"PATH", ctx.stub_path}, {"MIX_ENV", nil}, {"DATABASE_URL", nil}, {"PORT", nil}] ++ extra
  end

  defp mix_calls(ctx) do
    case File.read(ctx.calls) do
      {:ok, calls} -> String.split(calls, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  describe "refusals before any Mix command" do
    test "a non-demo MIX_ENV", ctx do
      assert {out, 2} = demo(["status"], stubbed(ctx, [{"MIX_ENV", "prod"}]))
      assert out =~ "MIX_ENV=prod is not the demo environment (dev)"
      assert mix_calls(ctx) == []
    end

    test "--test with another MIX_ENV", ctx do
      assert {out, 2} = demo(["--test", "seed"], stubbed(ctx, [{"MIX_ENV", "dev"}]))
      assert out =~ "--test needs MIX_ENV=test"
      assert mix_calls(ctx) == []
    end

    test "a DATABASE_URL in the environment", ctx do
      env = stubbed(ctx, [{"DATABASE_URL", "ecto://u:p@db.example.test/prod"}])
      assert {out, 2} = demo(["seed"], env)
      assert out =~ "DATABASE_URL is set"
      refute out =~ "u:p@"
      assert mix_calls(ctx) == []
    end

    test "reset without --yes", ctx do
      assert {out, 2} = demo(["reset"], stubbed(ctx))
      assert out =~ "reset drops and recreates sdr_agent_dev; re-run with --yes"
      assert mix_calls(ctx) == []
    end

    test "run on a port that is already in use", ctx do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
      {:ok, port} = :inet.port(socket)
      on_exit(fn -> :gen_tcp.close(socket) end)

      assert {out, 2} = demo(["run"], stubbed(ctx, [{"PORT", to_string(port)}]))
      assert out =~ "port #{port} is already in use"
      assert mix_calls(ctx) == []
    end

    test "run in --test mode", ctx do
      assert {out, 2} = demo(["--test", "run"], stubbed(ctx))
      assert out =~ "run starts the dev server; it has no --test mode"
      assert mix_calls(ctx) == []
    end

    test "an unknown command or none", ctx do
      assert {out, 2} = demo(["drop"], stubbed(ctx))
      assert out =~ "usage: bin/demo"
      assert {_out, 2} = demo([], stubbed(ctx))
      assert mix_calls(ctx) == []
    end
  end

  describe "the Repo Mix would use must be the local demo database" do
    for {line, reason} <- [
          {"SDR_DEMO_REPO db.example.test 5520 sdr_agent_dev",
           "database host db.example.test is not local"},
          {"SDR_DEMO_REPO localhost 5432 sdr_agent_dev",
           "database port 5432 is not the devenv Postgres port 5520"},
          {"SDR_DEMO_REPO localhost 5520 sdr_agent_prod",
           "database sdr_agent_prod is not the demo database sdr_agent_dev"}
        ] do
      test "refuses #{reason}", ctx do
        assert {out, 2} = demo(["seed"], stubbed(ctx, [{"STUB_REPO_LINE", unquote(line)}]))
        assert out =~ unquote(reason)
        assert [run] = mix_calls(ctx)
        assert run =~ "run --no-start -e"
      end
    end

    test "the demo database passes the check and the command runs", ctx do
      line = "SDR_DEMO_REPO localhost 5520 sdr_agent_dev"
      assert {_out, 0} = demo(["seed"], stubbed(ctx, [{"STUB_REPO_LINE", line}]))
      assert [_check, "sdr.demo.seed"] = mix_calls(ctx)
    end

    test "--test checks the suffixed partition database", ctx do
      env =
        stubbed(ctx, [
          {"MIX_TEST_PARTITION", "_x"},
          {"STUB_REPO_LINE", "SDR_DEMO_REPO localhost 5520 sdr_agent_test_x"}
        ])

      assert {out, 2} = demo(["--test", "seed"], env)
      assert out =~ "database sdr_agent_test_x is not the demo database sdr_agent_test_x_demo"
    end
  end

  test "--test reset, seed and status against the throw-away demo database" do
    env = [{"MIX_ENV", "test"}, {"DATABASE_URL", nil}]

    assert {out, 2} = demo(["--test", "reset"], env)
    assert out =~ "re-run with --yes"

    assert {reset, 0} = demo(["--test", "reset", "--yes"], env)
    assert reset =~ "is empty and migrated"

    assert {before, 0} = demo(["--test", "status"], env)
    assert before =~ "tenant: NOT SEEDED"

    assert {seed, 0} = demo(["--test", "seed"], env)
    assert seed =~ "Demo seed:"

    assert {status, 0} = demo(["--test", "status"], env)
    suppressed = length(Fixtures.suppressed_contact_emails())
    assert status =~ "server: n/a (--test)"
    assert status =~ "migrations: current"
    assert status =~ "tenant: seeded"
    assert status =~ "leads: new #{length(Fixtures.leads()) - suppressed}, stopped #{suppressed}"
    assert status =~ "drafts awaiting review: 0"
    assert status =~ "captured messages: 0"
    assert status =~ ~r/audit chain: valid \(\d+ events\)/
    assert status =~ "research"

    for output <- [reset, before, seed, status], %{password: password} <- Fixtures.users() do
      refute output =~ password
    end
  end
end

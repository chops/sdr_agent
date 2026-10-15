defmodule SdrAgent.Agents.GrantRestartProofTest do
  @moduledoc """
  C9-04 (#44) "survives restart": grant terms, allocations, an owner's
  release, revisions and charged attempts are all database state, read back
  by a fresh application boot. Characterization of merged behavior (no
  production change), not a RED test.

  The parent never touches the Repo. It owns one uniquely named synthetic
  database (`sdr_agent_test_rp<hex>` on the devenv port), and in it runs
  three separate OS processes with a scrubbed environment (`ChildEnv`,
  `MIX_ENV=test`, the Fake provider, no model launch):

    1. `ash.setup`, which creates and migrates the database;
    2. `setup.exs`, which commits the state through the domain APIs and exits;
    3. `verify.exs`, a fresh BEAM that reads that state back and admits
       against it.

  Each is bounded by a deadline and its exit status is checked. The owned
  database and temporary folder are removed afterwards, and nothing else.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.ChildEnv

  @moduletag :restart_proof
  @moduletag timeout: 900_000

  @scripts Path.expand("../../support/restart_proof", __DIR__)
  @root Path.expand("../../..", __DIR__)
  @deadline 300_000
  # The devenv toolchain's own locations, so the child uses the same pinned
  # Elixir, deps and build as this test (no provider or database settings).
  @toolchain ~w(MIX_HOME HEX_HOME MIX_DEPS_PATH MIX_BUILD_ROOT ERL_LIBS)

  setup do
    suffix = "_rp" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    database = "sdr_agent_test" <> suffix
    assert Regex.match?(~r/\Asdr_agent_test_rp[0-9a-f]{10}\z/, database)

    tmp = Path.join(System.tmp_dir!(), "sdr-restart-proof#{suffix}")
    File.mkdir_p!(tmp)
    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    on_exit(fn ->
      {out, status} = run(mix, ["ecto.drop", "--quiet"], suffix, 120_000)
      File.rm_rf!(tmp)
      if status != 0, do: IO.puts(:stderr, "restart proof: owned database not dropped\n#{out}")
    end)

    %{database: database, suffix: suffix, tmp: tmp, mix: mix}
  end

  test "a fresh boot reads persisted grant state and keeps counting charged attempts", ctx do
    setup_json = Path.join(ctx.tmp, "setup.json")
    result_json = Path.join(ctx.tmp, "result.json")

    {out, status} = run(ctx.mix, ["ash.setup", "--quiet"], ctx.suffix)
    assert status == 0, out

    {out, status} = run(ctx.mix, script("setup.exs", [ctx.database, setup_json]), ctx.suffix)
    assert status == 0, out

    setup = setup_json |> File.read!() |> JSON.decode!()
    assert setup["database"] == ctx.database
    assert length(setup["allocations"]) == 3

    {out, status} =
      run(ctx.mix, script("verify.exs", [ctx.database, setup_json, result_json]), ctx.suffix)

    assert File.exists?(result_json), "the verifier wrote no result:\n#{out}"
    result = result_json |> File.read!() |> JSON.decode!()
    failed = for {name, false} <- result["checks"], do: name

    assert failed == [], "restart checks failed: #{inspect(failed)}\n#{out}"
    assert map_size(result["checks"]) == 11
    assert result["ok"] == true
    assert status == 0, out
  end

  defp script(name, args) do
    ["run", "--no-compile", "--no-deps-check", Path.join(@scripts, name) | args]
  end

  # Literal argv, an allowlisted environment (`ChildEnv`) and a deadline;
  # a child still running at the deadline is killed and reported.
  defp run(mix, args, suffix, deadline \\ @deadline) do
    env =
      ChildEnv.port(@toolchain, [
        {"MIX_ENV", "test"},
        {"MIX_TEST_PARTITION", suffix}
      ])

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: @root,
        env: env
      ])

    collect(port, [], System.monotonic_time(:millisecond) + deadline)
  end

  defp collect(port, acc, until) do
    left = max(until - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], until)
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      left ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)])
          nil -> :ok
        end

        if Port.info(port), do: Port.close(port)
        {IO.iodata_to_binary(acc) <> "\n[killed at the deadline]", :timeout}
    end
  end
end

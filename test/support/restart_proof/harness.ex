defmodule SdrAgent.RestartProof.Harness do
  @moduledoc """
  Lifecycle of the C9-04 restart proof (`SdrAgent.Agents.GrantRestartProofTest`).

  `prove/1` claims resources, runs the children and cleans up:

    1. claims a temporary folder with `File.mkdir/1`; an existing folder
       is refused;
    2. claims the database by creating it in a child (`claim.exs`). That
       child validates the resolved target (name, localhost, port 5520,
       the test build) before creating anything. An existing database
       is refused and never migrated or dropped;
    3. migrates the database (`ash.setup`), then runs `setup.exs` and
       `verify.exs`, each in a fresh BEAM;
    4. cleans up only what it claimed: it drops the database through
       `drop.exs`, which validates the target again, then removes the
       folder.

  **When cleanup is skipped:** if any child's end can't be confirmed (a
  timeout whose kill isn't confirmed), nothing is cleaned up. The result
  is an error naming what is left behind.

  **When the result is an error:** any failed step or failed cleanup
  makes the result `{:error, _}`, so it can't pass.

  **The runner is injectable** so the lifecycle can be tested without a
  real database. A runner is `fn step, args -> outcome end`, where the
  outcome is one of:
  - `{:ok, output}`;
  - `{:exit, status, output}`;
  - `{:timeout, :confirmed | :unconfirmed, output}`.
  """

  alias SdrAgent.ChildEnv

  @database ~r/\Asdr_agent_test_rp[0-9a-f]{10}\z/
  @scripts Path.expand(".", __DIR__)
  # The devenv toolchain's own locations, so a child uses the same pinned
  # Elixir, deps and build (no provider or database settings).
  @toolchain ~w(MIX_HOME HEX_HOME MIX_DEPS_PATH MIX_BUILD_ROOT ERL_LIBS)
  @claim_refused 3

  def database_pattern, do: @database

  @doc "Runs the proof. Options: `:suffix`, `:tmp_root`, `:runner`."
  def prove(opts) do
    suffix = Keyword.fetch!(opts, :suffix)
    database = "sdr_agent_test" <> suffix
    runner = Keyword.fetch!(opts, :runner)
    tmp = Path.join(Keyword.fetch!(opts, :tmp_root), "sdr-restart-proof" <> suffix)

    with {:target, true} <- {:target, Regex.match?(@database, database)},
         {:tmp, :ok} <- {:tmp, File.mkdir(tmp)} do
      owned = %{tmp: tmp, database: nil}
      {outcome, owned} = run_owned(database, tmp, runner, owned)
      finish(outcome, owned, database, runner)
    else
      {:target, false} -> {:error, {:invalid_target, database}}
      {:tmp, {:error, reason}} -> {:error, {:tmp_not_claimed, tmp, reason}}
    end
  end

  defp run_owned(database, tmp, runner, owned) do
    case runner.(:claim, script("claim.exs", [database], start: false)) do
      {:ok, _} ->
        owned = %{owned | database: database}
        {steps(database, tmp, runner), owned}

      {:exit, @claim_refused, out} ->
        {{:error, {:database_not_claimed, out}}, owned}

      other ->
        # The claim may or may not have created the database: not owned,
        # never dropped; an unconfirmed child also stops all cleanup.
        {{:error, {:claim_failed, other}}, Map.put(owned, :unconfirmed, unconfirmed?(other))}
    end
  end

  defp steps(database, tmp, runner) do
    setup_json = Path.join(tmp, "setup.json")
    result_json = Path.join(tmp, "result.json")

    with {:ok, _} <- step(runner, :migrate, ["ash.setup", "--quiet"]),
         {:ok, _} <- step(runner, :setup, script("setup.exs", [database, setup_json])),
         {:ok, setup} <- read_json(setup_json),
         true <- setup["database"] == database || {:error, {:setup_database, setup["database"]}} do
      verify(runner, database, setup, setup_json, result_json)
    else
      {:error, _} = error -> error
      {:timeout, _, _} = timeout -> {:error, {:step_timeout, timeout}}
    end
  end

  defp verify(runner, database, setup, setup_json, result_json) do
    case runner.(:verify, script("verify.exs", [database, setup_json, result_json])) do
      {:timeout, _, _} = timeout ->
        {:error, {:step_timeout, timeout}}

      outcome ->
        case {outcome, read_json(result_json)} do
          {{:ok, _}, {:ok, result}} -> {:ok, %{setup: setup, result: result}}
          {outcome, result} -> {:error, {:verify, outcome, result}}
        end
    end
  end

  defp step(runner, name, args) do
    case runner.(name, args) do
      {:ok, out} -> {:ok, out}
      {:timeout, _, _} = timeout -> timeout
      other -> {:error, {name, other}}
    end
  end

  defp finish(outcome, owned, database, runner) do
    if Map.get(owned, :unconfirmed, false) or unconfirmed?(outcome) do
      {:error, {:cleanup_skipped_unconfirmed_child, outcome, owned}}
    else
      case cleanup(owned, database, runner) do
        :ok -> outcome
        {:error, reason} -> {:error, {:cleanup_failed, reason, outcome}}
      end
    end
  end

  defp cleanup(owned, database, runner) do
    dropped =
      case owned.database do
        nil -> :ok
        ^database -> drop(database, runner)
      end

    with :ok <- dropped do
      case File.rm_rf(owned.tmp) do
        {:ok, _} -> :ok
        {:error, reason, path} -> {:error, {:tmp_not_removed, path, reason}}
      end
    end
  end

  defp drop(database, runner) do
    case runner.(:drop, script("drop.exs", [database], start: false)) do
      {:ok, _} -> :ok
      other -> {:error, {:drop, other}}
    end
  end

  defp unconfirmed?({:timeout, :unconfirmed, _}), do: true
  defp unconfirmed?({:error, {:step_timeout, {:timeout, :unconfirmed, _}}}), do: true
  defp unconfirmed?(_), do: false

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- JSON.decode(body) do
      {:ok, json}
    else
      error -> {:error, {:unreadable_result, path, error}}
    end
  end

  defp script(name, args, opts \\ []) do
    start = if Keyword.get(opts, :start, true), do: [], else: ["--no-start"]
    ["run" | start] ++ ["--no-compile", "--no-deps-check", Path.join(@scripts, name) | args]
  end

  @doc """
  The real runner: `mix` with literal argv and a `ChildEnv` environment
  (`MIX_ENV=test`, the partition), from `root`, bounded by `deadline` ms.
  A child still running at the deadline is killed, and its exit is
  awaited for `grace` ms; `:confirmed` only once its exit status arrives.
  """
  def port_runner(executable, suffix, root, deadline, grace \\ 10_000) do
    env = ChildEnv.port(@toolchain, [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", suffix}])
    fn _step, args -> spawn_bounded(executable, args, root, env, deadline, grace) end
  end

  @doc "Runs one child; see `port_runner/5`."
  def spawn_bounded(executable, args, root, env, deadline, grace) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: root,
        env: env
      ])

    collect(port, [], System.monotonic_time(:millisecond) + deadline, grace)
  end

  defp collect(port, acc, until, grace) do
    left = max(until - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], until, grace)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, status}} -> {:exit, status, IO.iodata_to_binary(acc)}
    after
      left -> kill(port, acc, grace)
    end
  end

  defp kill(port, acc, grace) do
    killed? =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          {_, status} =
            System.cmd("kill", ["-KILL", Integer.to_string(pid)],
              env: ChildEnv.cmd([]),
              stderr_to_stdout: true
            )

          status == 0

        nil ->
          false
      end

    confirmed = if killed?, do: await_exit(port, acc, grace), else: :unconfirmed
    {:timeout, confirmed, IO.iodata_to_binary(acc)}
  end

  defp await_exit(port, acc, grace) do
    receive do
      {^port, {:data, data}} -> await_exit(port, [acc | data], grace)
      {^port, {:exit_status, _}} -> :confirmed
    after
      grace -> :unconfirmed
    end
  end
end

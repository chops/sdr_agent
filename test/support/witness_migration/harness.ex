defmodule SdrAgent.WitnessMigration.Harness do
  @moduledoc """
  Lifecycle of the projection v4 lineage migration campaign (witness
  response-block plan r5, T4 group 2; `SdrAgent.Agents.WitnessLineageMigrationTest`,
  tagged `:external`, run only by the explicit campaign command).

  It follows the ownership discipline of the C9-04 restart proof
  (`SdrAgent.RestartProof.Harness`), not its grant-proof semantics or its
  database pattern. `prove/1`:

    1. refuses a database name other than `sdr_agent_test_wm<10 hex>` and
       claims a temporary folder with `File.mkdir/1` (an existing folder is
       refused);
    2. claims the database by creating it in a child (`claim.exs`). Before
       creating anything that child validates the exact name, the resolved
       host and port 5520, `MIX_ENV=test` and the Fake provider. Creating a
       previously absent database is the ownership receipt; an existing
       database is refused and never adopted, migrated or dropped;
    3. in children (`migrate.exs`, each validating the target again before
       it opens a connection), migrates the owned database to the immediate
       predecessor of the new migration, then runs the new migration up,
       down and up again;
    4. after each of those four states, proves the installed lineage
       function's behaviour in a child (`probe.exs`) by raw inserts inside
       rolled-back transactions, against heads committed once in the owned
       database (never by matching source strings);
    5. cleans up only what it claimed: a normal drop of the owned database
       through `drop.exs` (no `FORCE`, no connection termination), after
       every child has exited, then the folder.

  Any failed step or failed cleanup makes the result `{:error, _}`. If a
  child's end cannot be confirmed, nothing is cleaned up and the error
  names what is left behind. The parent test Repo and application
  configuration are never changed.

  The runner is injectable (the same contract as the restart proof's): a
  runner is `fn step, args -> outcome end` with outcome `{:ok, output}`,
  `{:exit, status, output}` or `{:timeout, :confirmed | :unconfirmed,
  output}`. The real runner is `SdrAgent.RestartProof.Harness.port_runner/5`.
  """

  @database ~r/\Asdr_agent_test_wm[0-9a-f]{10}\z/
  @migration "_v4_mismatch_lineage.exs"
  @scripts Path.expand(".", __DIR__)
  @claim_refused 3

  @doc "The only database names this campaign may claim."
  def database_pattern, do: @database

  @doc """
  The new migration's version and its immediate predecessor in `dir`:
  `{:ok, %{new:, predecessor:}}`, `{:error, :migration_absent}`,
  `{:error, {:migration_ambiguous, files}}` or `{:error, :no_predecessor}`.
  """
  def versions(dir) do
    versions =
      for file <- File.ls!(dir),
          String.ends_with?(file, ".exs"),
          {version, ""} <- [Integer.parse(hd(String.split(file, "_", parts: 2)))],
          do: {version, file}

    case Enum.filter(versions, fn {_version, file} -> String.ends_with?(file, @migration) end) do
      [] -> {:error, :migration_absent}
      [{new, _file}] -> with_predecessor(new, versions)
      many -> {:error, {:migration_ambiguous, Enum.map(many, &elem(&1, 1))}}
    end
  end

  defp with_predecessor(new, versions) do
    case Enum.filter(Enum.map(versions, &elem(&1, 0)), &(&1 < new)) do
      [] -> {:error, :no_predecessor}
      older -> {:ok, %{new: new, predecessor: Enum.max(older)}}
    end
  end

  @doc """
  Runs the campaign. Options: `:suffix` (`"_wm<10 hex>"`), `:tmp_root`,
  `:versions` (from `versions/1`), `:runner`. Returns `{:ok, states}`,
  where `states` maps `"predecessor"`, `"up"`, `"down"` and `"up_again"`
  to that state's probe checks, or `{:error, reason}`.
  """
  def prove(opts) do
    suffix = Keyword.fetch!(opts, :suffix)
    database = "sdr_agent_test" <> suffix
    runner = Keyword.fetch!(opts, :runner)
    versions = Keyword.fetch!(opts, :versions)
    tmp = Path.join(Keyword.fetch!(opts, :tmp_root), "sdr-witness-migration" <> suffix)

    with {:target, true} <- {:target, Regex.match?(@database, database)},
         {:tmp, :ok} <- {:tmp, File.mkdir(tmp)} do
      owned = %{tmp: tmp, database: nil}
      {outcome, owned} = run_owned(database, tmp, versions, runner, owned)
      finish(outcome, owned, database, runner)
    else
      {:target, false} -> {:error, {:invalid_target, database}}
      {:tmp, {:error, reason}} -> {:error, {:tmp_not_claimed, tmp, reason}}
    end
  end

  defp run_owned(database, tmp, versions, runner, owned) do
    case runner.(:claim, script("claim.exs", [database], start: false)) do
      {:ok, _} ->
        owned = %{owned | database: database}
        {steps(database, tmp, versions, runner), owned}

      {:exit, @claim_refused, out} ->
        {{:error, {:database_not_claimed, out}}, owned}

      other ->
        # The claim may or may not have created the database: not owned,
        # never dropped; an unconfirmed child also stops all cleanup.
        {{:error, {:claim_failed, other}}, Map.put(owned, :unconfirmed, unconfirmed?(other))}
    end
  end

  # predecessor -> new up -> new down -> new up, probing after each.
  defp steps(database, tmp, %{new: new, predecessor: predecessor}, runner) do
    fixtures = Path.join(tmp, "fixtures.json")

    plan = [
      {"up", predecessor, "predecessor"},
      {"up", new, "up"},
      {"down", new, "down"},
      {"up", new, "up_again"}
    ]

    Enum.reduce_while(plan, {:ok, %{}}, fn {direction, version, label}, {:ok, states} ->
      args =
        script("migrate.exs", [database, direction, Integer.to_string(version)], start: false)

      out = Path.join(tmp, label <> ".json")

      with {:ok, _} <- step(runner, :migrate, args),
           {:ok, _} <- step(runner, :probe, script("probe.exs", [database, label, fixtures, out])),
           {:ok, probe} <- read_json(out),
           true <- probe["database"] == database || {:error, {:probe_database, probe["database"]}} do
        {:cont, {:ok, Map.put(states, label, probe["checks"])}}
      else
        {:timeout, _, _} = timeout -> {:halt, {:error, {:step_timeout, label, timeout}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
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
  defp unconfirmed?({:error, {:step_timeout, _label, {:timeout, :unconfirmed, _}}}), do: true
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
end

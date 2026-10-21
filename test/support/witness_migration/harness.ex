defmodule SdrAgent.WitnessMigration.Harness do
  @moduledoc """
  Lifecycle of the projection v4 lineage migration campaign (witness
  response-block plan r5, T4 group 2; `SdrAgent.Agents.WitnessLineageMigrationTest`,
  tagged `:external`, run only by the explicit campaign command). Its
  stubbed lifecycle and target checks are `SdrAgent.Agents.WitnessMigrationHarnessTest`
  (no database).

  It follows the ownership discipline of the C9-04 restart proof
  (`SdrAgent.RestartProof.Harness`), not its grant-proof semantics or its
  database pattern. `prove/1`:

    1. refuses a database name other than `sdr_agent_test_wm<10 hex>` and
       claims a temporary folder with `File.mkdir/1` (an existing folder is
       refused);
    2. claims the database by creating it in a child (`claim.exs`). Every
       child runs with `mix run --no-start` and, as its first effectful
       statement, validates the target (`check_target/2`: the exact name,
       the configured database, the resolved host and port 5520,
       `MIX_ENV=test` and the Fake provider); a refusal exits
       with status 4 (`REFUSED <reason>`) before any startup, connection or other
       effect. Creating a previously absent database is the ownership
       receipt; an existing database is refused and never adopted,
       migrated or dropped;
    3. in children (`migrate.exs`, starting only Postgrex, Ecto SQL and the
       Repo after validation), migrates the owned database to the
       immediate predecessor of the new migration, then runs the new
       migration up, down and up again;
    4. after each of those four states, proves the installed lineage
       function's behaviour in a child (`probe.exs`, starting the
       application explicitly only after validation, since its committed
       heads are made through the domain APIs) by raw inserts inside
       rolled-back transactions, against heads committed once in the owned
       database (never by matching source strings). Each probe result must
       be a JSON object naming this database and state label, with a
       non-empty map of string check results;
    5. cleans up only what it claimed: a normal drop of the owned database
       through `drop.exs` (no `FORCE`, no connection termination), after
       every child has exited, then the folder.

  **Failures after ownership.** Once the claim has confirmed ownership,
  only failures whose child is proven gone or never started still go
  through cleanup: a confirmed exit (`{:exit, status, _}`), a confirmed
  timeout (`{:timeout, :confirmed, _}`), a typed pre-spawn refusal
  (`{:not_started, reason}`), and, after a completed runner result, an
  unreadable or invalid probe result or an exception in local result
  parsing or validation. A failed cleanup keeps both errors:
  `{:error, {:cleanup_failed, cleanup_error, original_outcome}}`.

  **Uncertainty is never ownership, and never cleaned up.** A child whose
  end is not confirmed (`{:timeout, :unconfirmed, _}`), and any untyped
  runner exception, throw or exit (`{:raised, _}`), retain the database and
  the folder: nothing is dropped or removed, and the error reports the
  original failure with what is left behind. A runner exception proves
  nothing about its child: the real runner can raise after the port is
  open, for example when its timeout kill (`System.cmd("kill", ...)`)
  itself fails while the child may still be running, and a successful
  drop would not prove that child gone either. No exception class is taken
  as proof of termination. A claim that raised is uncertain in the same
  way (whether the database was created is unknown).

  The parent test Repo and application configuration are never changed.

  The runner is injectable: a runner is `fn step, args -> outcome end`
  with outcome `{:ok, output}`, `{:exit, status, output}`, `{:timeout,
  :confirmed | :unconfirmed, output}` (the restart proof's contract) or
  `{:not_started, reason}`, which a runner returns only when it has proven
  that it spawned nothing. The real runner is `checked_runner/4`: it
  returns `{:not_started, _}` for an unusable executable, checked before
  spawning, and otherwise delegates to
  `SdrAgent.RestartProof.Harness.port_runner/5`.
  """

  alias SdrAgent.RestartProof.Harness, as: Bounded

  @database ~r/\Asdr_agent_test_wm[0-9a-f]{10}\z/
  @migration "_v4_mismatch_lineage.exs"
  @scripts Path.expand(".", __DIR__)
  @claim_refused 3
  @target_refused 4

  @doc """
  The real runner: `{:not_started, {:executable_unusable, executable}}`,
  without spawning anything, unless `executable` is an existing regular
  file with an execute bit; otherwise
  `SdrAgent.RestartProof.Harness.port_runner/5` with the same arguments.
  An exception from that runner is never typed: it is held as uncertain.
  """
  def checked_runner(executable, suffix, root, deadline) do
    runner = Bounded.port_runner(executable, suffix, root, deadline)

    fn step, args ->
      if executable?(executable),
        do: runner.(step, args),
        else: {:not_started, {:executable_unusable, executable}}
    end
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable?(_path), do: false

  @doc "The only database names this campaign may claim."
  def database_pattern, do: @database

  @doc "The exit status of a child that refused its target (`REFUSED <reason>`)."
  def target_refused, do: @target_refused

  @doc """
  Pure target check, made by every child before any startup, connection
  or effect. `facts` are the child's resolved `database`, `hostname`,
  `port`, `env` (`Mix.env/0`) and `provider` (the configured model
  provider). Returns `:ok` or `{:error, reason}`.
  """
  def check_target(database, facts) do
    cond do
      not (is_binary(database) and Regex.match?(@database, database)) ->
        {:error, :invalid_target}

      facts[:database] != database ->
        {:error, :target_not_configured}

      facts[:hostname] != "localhost" ->
        {:error, :host_not_local}

      facts[:port] != 5520 ->
        {:error, :port_not_5520}

      facts[:env] != :test ->
        {:error, :env_not_test}

      facts[:provider] != SdrAgent.AI.ModelProvider.Fake ->
        {:error, :provider_not_fake}

      true ->
        :ok
    end
  end

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
    case run(runner, :claim, script("claim.exs", [database])) do
      {:ok, _} ->
        owned = %{owned | database: database}
        {guarded_steps(database, tmp, versions, runner), owned}

      {:exit, @claim_refused, out} ->
        {{:error, {:database_not_claimed, out}}, owned}

      {:raised, _} = raised ->
        # Whether the database was created is unknown: never owned, never
        # dropped, and nothing else is cleaned up either.
        {{:error, {:claim_failed, raised}}, Map.put(owned, :unconfirmed, true)}

      other ->
        # The claim may or may not have created the database: not owned,
        # never dropped; an unconfirmed child also stops all cleanup.
        {{:error, {:claim_failed, other}}, Map.put(owned, :unconfirmed, unconfirmed?(other))}
    end
  end

  # Ownership is confirmed here. Runner exceptions never reach this rescue
  # (`run/3` holds them as `{:raised, _}`, which `finish/4` never cleans
  # up); what does is an exception in local result parsing or validation
  # after a completed runner result, which still reaches the owned cleanup.
  defp guarded_steps(database, tmp, versions, runner) do
    steps(database, tmp, versions, runner)
  rescue
    exception -> {:error, {:local_exception, exception}}
  catch
    kind, reason -> {:error, {:local_exception, {kind, reason}}}
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
      migrate = script("migrate.exs", [database, direction, Integer.to_string(version)])
      out = Path.join(tmp, label <> ".json")

      with {:ok, _} <- step(runner, :migrate, migrate),
           {:ok, _} <- step(runner, :probe, script("probe.exs", [database, label, fixtures, out])),
           {:ok, probe} <- read_json(out),
           {:ok, checks} <- probe_checks(probe, database, label) do
        {:cont, {:ok, Map.put(states, label, checks)}}
      else
        {:timeout, _, _} = timeout -> {:halt, {:error, {:step_timeout, label, timeout}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Validates one probe result: a JSON object naming `database` and `label`,
  whose `checks` is a non-empty map of string results. Returns `{:ok,
  checks}` or `{:error, reason}`.
  """
  def probe_checks(probe, database, label) do
    case probe do
      %{"database" => ^database, "label" => ^label, "checks" => %{} = checks}
      when map_size(checks) > 0 ->
        string_checks(checks, label)

      %{"database" => other} when other != database ->
        {:error, {:probe_database, label, other}}

      %{} ->
        {:error, {:probe_result_invalid, label}}

      _not_a_map ->
        {:error, {:probe_result_not_a_map, label}}
    end
  end

  defp string_checks(checks, label) do
    if Enum.all?(checks, fn {name, value} -> is_binary(name) and is_binary(value) end),
      do: {:ok, checks},
      else: {:error, {:probe_checks_invalid, label}}
  end

  defp step(runner, name, args) do
    case run(runner, name, args) do
      {:ok, out} -> {:ok, out}
      {:timeout, _, _} = timeout -> timeout
      other -> {:error, {name, other}}
    end
  end

  # A runner exception is reported as `{:raised, _}`, never re-raised, and
  # is always uncertain (`unconfirmed?/1`): it proves nothing about its child.
  defp run(runner, name, args) do
    runner.(name, args)
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:raised, {kind, reason}}
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
    case run(runner, :drop, script("drop.exs", [database])) do
      {:ok, _} -> :ok
      other -> {:error, {:drop, other}}
    end
  end

  defp unconfirmed?({:timeout, :unconfirmed, _}), do: true
  defp unconfirmed?({:raised, _}), do: true
  defp unconfirmed?({:error, {:step_timeout, _label, {:timeout, :unconfirmed, _}}}), do: true
  defp unconfirmed?({:error, {_step, {:raised, _}}}), do: true
  defp unconfirmed?(_), do: false

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- JSON.decode(body) do
      {:ok, json}
    else
      error -> {:error, {:unreadable_result, path, error}}
    end
  end

  # Every child starts with `--no-start`: it validates its target before it
  # starts anything itself.
  defp script(name, args),
    do: ["run", "--no-start", "--no-compile", "--no-deps-check", Path.join(@scripts, name) | args]
end

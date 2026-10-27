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
       every child has exited, then the folder. The drop child first drains
       like the standing lane runner's r7b (`drop_flow/1`, protocol v2):
       only exact `autovacuum worker` backends may remain, inside one fixed
       monotonic budget, and they are counted, never reported as zero.

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

  **Parameterization** (C2* S3 release-migration campaign, S3 plan r2
  section 9; `SdrAgent.Agents.ReleaseMigrationTest`, `:external`; its
  stubbed contract is `SdrAgent.Agents.ReleaseMigrationHarnessTest`). Every
  default is the lineage campaign's, unchanged:

    * `versions/2` takes `:migration_suffix` (default
      `"_v4_mismatch_lineage.exs"`);
    * `prove/1` takes `:probe` (one closed probe script, or one per probe
      state), `:runners` (a runner per migrate or probe step of the plan;
      the claim and the drop always run on `:runner`, so ownership and
      cleanup never move) and `:plan` (`:continuity`, or `:down_refusal`:
      up, a `down` that must be refused with `check_violation`, then the
      `after_refusal` probe). Every option, and every unknown option, is
      validated before anything is claimed;
    * `checked_runner/5` with `toolchain: :root` builds a runner whose
      child uses another checkout's own build (`root_child_env/4`), after
      physical root checks; `toolchain: :inherit` is `checked_runner/4`;
    * `prove/1` takes `:evidence_dir` (Codex e95a7340 choice 2): the
      harness itself exports its evidence there, before the folder is
      removed (see `prove/1`); without it nothing is exported or recorded;
    * `campaign_targets/2` reads the campaign's two predeclared targets
      (choice 1): no random fallback.
  """

  alias SdrAgent.RestartProof.Harness, as: Bounded

  @database ~r/\Asdr_agent_test_wm[0-9a-f]{10}\z/
  @migration "_v4_mismatch_lineage.exs"
  @migration_shape ~r/\A_[a-z0-9_]{1,96}\.exs\z/
  @scripts Path.expand(".", __DIR__)
  @support Path.expand("..", __DIR__)
  @own_root Path.expand("../../..", __DIR__)
  @probes ~w(witness_migration/probe.exs release_migration/baseline.exs
             release_migration/probe.exs release_migration/demo.exs)
  @mix_roots ~w(MIX_HOME HEX_HOME MIX_DEPS_PATH MIX_BUILD_ROOT)
  @code_path_removed ~w(ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS MIX_PATH
                        MIX_ARCHIVES MIX_EXS MIX_BUILD_PATH)
  @store_path ~r|\A/nix/store/[0-9a-z]{32}-[^/]+(/[^/]+)*\z|
  @prove_options [:suffix, :tmp_root, :versions, :runner, :probe, :runners, :plan, :evidence_dir]
  @check_violation ~r/^\*\* \(Postgrex\.Error\) ERROR 23514 \(check_violation\) /m
  @children {__MODULE__, :children}
  @claim_refused 3
  @db1_var "SDR_RELEASE_DB1_SUFFIX"
  @db2_var "SDR_RELEASE_DB2_SUFFIX"
  @marker_reserve 64
  @output_limit 65_536
  @receipts {__MODULE__, :receipts}
  @target_refused 4
  @target_suffix ~r/\A_wm[0-9a-f]{10}\z/

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

  @doc """
  `toolchain: :inherit` is exactly `checked_runner/4`. `toolchain: :root`
  builds a runner for a separate checkout's own build at `root` (the OLD
  baseline): each call refuses, as `{:not_started, reason}` and before
  the executable check and before anything is spawned, in this order:

    * `{:own_root_unusable, path}`: this checkout cannot be resolved
      physically (by lstat and readlink, no shell);
    * `{:root_unusable, root}`: `root` is not an absolute normalized path
      of an existing directory that is physically itself (no symlink at it
      or at any ancestor);
    * `{:root_shared, root}`: `root` is, lies inside or contains this
      checkout (physically);
    * a `root_child_env/4` refusal;
    * `{:toolchain_unusable, name}`: a re-rooted Mix root has a missing,
      non-directory or symlinked component below `root`.

  The child's environment is `SdrAgent.ChildEnv.port([], set)` with the
  `root_child_env/4` set (snapshot of this process's environment taken
  when the runner is built): ChildEnv's policy is unchanged, so only its
  base names are inherited (`PATH` among them: the executable and the
  pinned Elixir wrapper's own Erlang are fixed paths) and its secrets are
  always removed. Any other option raises `ArgumentError`.
  """
  def checked_runner(executable, suffix, root, deadline, opts) do
    case runner_mode!(opts) do
      :inherit -> checked_runner(executable, suffix, root, deadline)
      :root -> root_runner(executable, suffix, root, deadline, System.get_env())
    end
  end

  defp root_runner(executable, suffix, root, deadline, snapshot) do
    fn _step, args ->
      with {:ok, own_root} <- own_root(),
           :ok <- usable_root(root),
           :ok <- unshared_root(root, own_root),
           {:ok, set} <- not_started(root_child_env(own_root, root, suffix, snapshot)),
           :ok <- usable_toolchain(root, Enum.filter(set, &(elem(&1, 0) in @mix_roots))),
           :ok <- usable_executable(executable) do
        env = SdrAgent.ChildEnv.port([], set)
        Bounded.spawn_bounded(executable, args, root, env, deadline, 10_000)
      end
    end
  end

  defp runner_mode!(opts) do
    case opts do
      [toolchain: mode] when mode in [:inherit, :root] -> mode
      other -> raise ArgumentError, "checked_runner/5 options: #{inspect(other)}"
    end
  end

  defp not_started({:ok, set}), do: {:ok, set}
  defp not_started({:error, reason}), do: {:not_started, reason}

  # This checkout's physical path, or a refusal (never its lexical alias).
  defp own_root do
    case physical_path(@own_root) do
      {:ok, path} -> if File.dir?(path), do: {:ok, path}, else: own_root_unusable()
      :error -> own_root_unusable()
    end
  end

  defp own_root_unusable, do: {:not_started, {:own_root_unusable, @own_root}}

  # Resolves every symlinked component of an absolute path by lstat and
  # readlink, with a bound on the number of links followed. A link target
  # with a "." or ".." segment is refused rather than resolved lexically.
  defp physical_path(path) do
    if normalized_absolute?(path), do: resolve(Path.split(path), "/", 40), else: :error
  end

  defp resolve([], acc, _hops), do: {:ok, acc}
  defp resolve(_parts, _acc, 0), do: :error

  defp resolve([part | rest], acc, hops) do
    next = Path.join(acc, part)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} -> follow(File.read_link(next), acc, rest, hops)
      {:ok, _stat} -> resolve(rest, next, hops)
      {:error, _reason} -> :error
    end
  end

  defp follow({:ok, target}, acc, rest, hops) do
    parts = Path.split(target)

    cond do
      Enum.any?(parts, &(&1 in [".", ".."])) -> :error
      Path.type(target) == :absolute -> resolve(parts ++ rest, "/", hops - 1)
      true -> resolve(parts ++ rest, acc, hops - 1)
    end
  end

  defp follow({:error, _reason}, _acc, _rest, _hops), do: :error

  # An existing directory, physically itself: no symlink at it or at any
  # ancestor.
  defp usable_root(root) do
    if normalized_absolute?(root) and
         match?({:ok, %File.Stat{type: :directory}}, File.lstat(root)) and
         physical?(root),
       do: :ok,
       else: {:not_started, {:root_unusable, root}}
  end

  defp physical?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: type}} when type != :symlink, File.lstat(&1)))
  end

  defp unshared_root(root, own_root) do
    if shared?(root, own_root),
      do: {:not_started, {:root_shared, root}},
      else: :ok
  end

  # Equal, inside, or containing (both normalized absolute paths).
  defp shared?(root, own_root) do
    root == own_root or String.starts_with?(root, own_root <> "/") or
      String.starts_with?(own_root, String.trim_trailing(root, "/") <> "/")
  end

  # Every component from `root` down to each Mix root is a real directory.
  defp usable_toolchain(root, pairs) do
    Enum.find_value(pairs, :ok, fn {name, path} ->
      real? =
        path
        |> Path.relative_to(root)
        |> Path.split()
        |> Enum.scan(root, &Path.join(&2, &1))
        |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1)))

      if real?, do: nil, else: {:not_started, {:toolchain_unusable, name}}
    end)
  end

  defp usable_executable(executable) do
    if executable?(executable),
      do: :ok,
      else: {:not_started, {:executable_unusable, executable}}
  end

  @doc """
  Pure and lexical: the four Mix roots (`MIX_HOME`, `HEX_HOME`,
  `MIX_DEPS_PATH`, `MIX_BUILD_ROOT`) for a child built in `root`, each of
  the parent's (`env`) re-rooted from `own_root` to `root`. Returns
  `{:ok, [{name, path}]}` in that order, or `{:error, reason}`:
  `{:root_invalid, root}` (not an absolute normalized path), `{:root_shared,
  root}` (it is, lies inside or contains `own_root`), `{:toolchain_unset,
  name}` or `{:toolchain_outside_root, name}` (a value not strictly inside
  `own_root`: there is no fallback to the parent's own build). It decides
  nothing about any other name (that is `root_child_env/4`) and checks
  nothing on disk (that is `checked_runner/5`).
  """
  def root_toolchain(own_root, root, env) do
    cond do
      not normalized_absolute?(root) -> {:error, {:root_invalid, root}}
      shared?(root, own_root) -> {:error, {:root_shared, root}}
      true -> rerooted(own_root, root, env)
    end
  end

  @doc """
  Pure: the `SdrAgent.ChildEnv` `set` of a root-mode child, one entry per
  name: the `root_toolchain/3` Mix roots (its refusals come first);
  `ERL_LIBS` with its value only when every `:`-separated entry is an
  immutable `/nix/store/<hash>-<name>` path (normalized; no mutable
  profile, checkout, empty entry or traversal), `nil` (an explicit removal)
  when unset, and otherwise `{:error, {:code_path_unapproved, "ERL_LIBS"}}`;
  explicit removals of the other code-path names (`ERL_FLAGS`, `ERL_AFLAGS`,
  `ERL_ZFLAGS`, `ELIXIR_ERL_OPTIONS`, `MIX_PATH`, `MIX_ARCHIVES`, `MIX_EXS`,
  `MIX_BUILD_PATH`); `MIX_ENV=test`; and the partition `suffix`. This is an
  admissibility check on names and paths, not a provenance proof of the
  store artifacts: the campaign packet pins those.
  """
  def root_child_env(own_root, root, suffix, env) do
    with {:ok, roots} <- root_toolchain(own_root, root, env),
         {:ok, erl_libs} <- approved_code_path(Map.get(env, "ERL_LIBS")) do
      {:ok,
       roots ++
         [{"ERL_LIBS", erl_libs}] ++
         Enum.map(@code_path_removed, &{&1, nil}) ++
         [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", suffix}]}
    end
  end

  defp approved_code_path(nil), do: {:ok, nil}

  defp approved_code_path(value) do
    entries = String.split(value, ":")

    if Enum.all?(entries, &store_path?/1),
      do: {:ok, value},
      else: {:error, {:code_path_unapproved, "ERL_LIBS"}}
  end

  defp store_path?(entry) do
    trimmed = String.trim_trailing(entry, "/")
    trimmed != "" and Path.expand(trimmed) == trimmed and Regex.match?(@store_path, trimmed)
  end

  defp rerooted(own_root, root, env) do
    @mix_roots
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case reroot(name, Map.fetch(env, name), own_root, root) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end)
  end

  defp reroot(name, :error, _own_root, _root), do: {:error, {:toolchain_unset, name}}

  defp reroot(name, {:ok, value}, own_root, root) do
    if inside?(value, own_root),
      do: {:ok, {name, Path.join(root, Path.relative_to(value, own_root))}},
      else: {:error, {:toolchain_outside_root, name}}
  end

  defp normalized_absolute?(path),
    do:
      is_binary(path) and path != "" and Path.type(path) == :absolute and
        Path.expand(path) == path

  defp inside?(value, own_root),
    do: normalized_absolute?(value) and String.starts_with?(value, own_root <> "/")

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
  Pure: the release-migration campaign's two predeclared targets (Codex
  e95a7340 choice 1), read from `env` (a map, such as `System.get_env/0`):
  `SDR_RELEASE_DB1_SUFFIX` and `SDR_RELEASE_DB2_SUFFIX`, each exactly
  `_wm<10 lowercase hex>`. `parent` is the parent's own configured
  database. Returns `{:ok, %{db1: {suffix, database}, db2: {suffix,
  database}}}`, or the first refusal, in this order: `{:error,
  {:target_unset, var}}` or `{:error, {:target_invalid, var}}` (DB #1's
  variable before DB #2's), `{:error, :targets_identical}`, `{:error,
  {:target_is_parent, var}}`. There is no random fallback. A valid name is
  not ownership: each target is still claimed by exclusive create, an
  existing database is refused and never adopted, and only an owned
  target is ever dropped (`prove/1`).
  """
  def campaign_targets(env, parent) when is_map(env) and is_binary(parent) do
    with {:ok, db1} <- campaign_target(env, @db1_var),
         {:ok, db2} <- campaign_target(env, @db2_var),
         :ok <- distinct_targets(db1, db2),
         :ok <- not_parent(db1, @db1_var, parent),
         :ok <- not_parent(db2, @db2_var, parent) do
      {:ok, %{db1: db1, db2: db2}}
    end
  end

  defp campaign_target(env, var) do
    case Map.fetch(env, var) do
      {:ok, suffix} ->
        if is_binary(suffix) and Regex.match?(@target_suffix, suffix),
          do: {:ok, {suffix, "sdr_agent_test" <> suffix}},
          else: {:error, {:target_invalid, var}}

      :error ->
        {:error, {:target_unset, var}}
    end
  end

  defp distinct_targets({same, _}, {same, _}), do: {:error, :targets_identical}
  defp distinct_targets(_db1, _db2), do: :ok

  defp not_parent({_suffix, parent}, var, parent), do: {:error, {:target_is_parent, var}}
  defp not_parent(_target, _var, _parent), do: :ok

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
  The new migration is the one file ending in `:migration_suffix` (default
  `"_v4_mismatch_lineage.exs"`; shape `_<a-z0-9_>.exs`); a bad suffix or
  any other option is `{:error, {:invalid_option, key}}`.
  """
  def versions(dir, opts \\ []) do
    with {:ok, migration} <- migration_suffix(opts), do: select_versions(dir, migration)
  end

  defp select_versions(dir, migration) do
    versions =
      for file <- File.ls!(dir),
          String.ends_with?(file, ".exs"),
          {version, ""} <- [Integer.parse(hd(String.split(file, "_", parts: 2)))],
          do: {version, file}

    case Enum.filter(versions, fn {_version, file} -> String.ends_with?(file, migration) end) do
      [] -> {:error, :migration_absent}
      [{new, _file}] -> with_predecessor(new, versions)
      many -> {:error, {:migration_ambiguous, Enum.map(many, &elem(&1, 1))}}
    end
  end

  defp migration_suffix(opts) do
    case Keyword.keys(opts) -- [:migration_suffix] do
      [] ->
        suffix = Keyword.get(opts, :migration_suffix, @migration)

        if is_binary(suffix) and Regex.match?(@migration_shape, suffix),
          do: {:ok, suffix},
          else: {:error, {:invalid_option, :migration_suffix}}

      [key | _] ->
        {:error, {:invalid_option, key}}
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
  `:versions` (from `versions/1,2`), `:runner`, and optionally:

    * `:plan`: `:continuity` (default; predecessor -> new up -> new down ->
      new up, probing after each) or `:down_refusal` (new up and probe;
      new down, which must end in a confirmed integer nonzero exit, not the
      target refusal, whose output has a line starting
      `** (Postgrex.Error) ERROR 23514 (check_violation) `; then the
      `after_refusal` probe). Any other down outcome is `{:error,
      {:down_refusal, :not_refused | :untyped | :target_refused, outcome}}`
      after a confirmed exit, or today's typed step error otherwise. The
      SQLSTATE line types the refusal; it does not prove the rollback,
      which is the `after_refusal` probe's job;
    * `:probe`: the probe script for every probe state, or a map naming
      exactly the plan's probe states (default `witness_migration/probe.exs`);
      only `witness_migration/probe.exs` and `release_migration/{baseline,
      probe,demo}.exs` of this support tree, as absolute normalized paths
      of existing regular files;
    * `:runners`: `%{{:migrate | :probe, state} => runner}` for the plan's
      own steps; the claim and the drop always run on `:runner`;
    * `:evidence_dir`: a destination for this run's evidence, exported by
      the harness itself. It must be an absolute normalized path whose
      parent is an existing directory, physically itself (no symlink at
      the parent or any ancestor), and it must not be, lie inside or
      contain this checkout or the harness folder (lexically or
      physically). After the target check and before the folder is
      claimed, it is claimed by `File.mkdir/1` and made 0700: an existing
      path is `{:error, {:evidence_not_claimed, dir, reason}}`, refused
      before any child and never adopted. A claimed evidence directory is
      never removed by any cleanup (when the folder then cannot be
      claimed, it stays empty).

  **Evidence export.** With `:evidence_dir`, every child is recorded in
  order (`NN-claim`, `NN-migrate-<direction>-<version>`,
  `NN-probe-<state>`, `NN-drop`) with its closed outcome and its output,
  bounded to 64 KiB in total, the marker included (over that, the first
  and last 32,736 bytes around a `[... <n> bytes elided ...]` line); a runner exception is recorded by its type only, a typed
  pre-spawn refusal by its tag only. On every path after the folder was
  claimed, the harness exports, after the drop (or when none is owed) and
  before the folder is removed: `files/<name>` for each of the folder's
  closed captures and results (`fixtures.json` and `<state>.json` for the
  plan's probe states), regular files only (by lstat; a symlink is never
  followed); `children/<NN-child>.status` and `.out`. Every file is created
  exclusively and made 0600 (`files/` and `children/` 0700). Only when
  every one is exported does it write the seal, `SHA256SUMS` (`<sha256>
  <path>` per file, sorted), last. Anything else in the folder, or any
  failed read or write, leaves the export unsealed: `{:error,
  {:cleanup_failed, {:evidence_incomplete, problems}, outcome}}`, with the
  owned database still dropped and the folder (the source) retained. An
  unconfirmed child still retains everything; its evidence is exported
  all the same and the result stays `{:error,
  {:cleanup_skipped_unconfirmed_child, _, _}}`.

  An invalid value, or any other option, is `{:error, {:invalid_option,
  key}}` before anything is claimed. Returns `{:ok, states}`, where
  `states` maps each probed state to its probe checks, or `{:error,
  reason}`.
  """
  def prove(opts), do: opts |> prove_with_receipts() |> elem(0)

  @doc """
  `prove/1`, plus its operational receipt (Codex 9ef62e5 G2): `{outcome,
  receipts}`, where `receipts` is the ordered list of `{key, value}` facts
  this run observed, one fact each, with closed keys and closed or
  synthetic values only (never row content, output text or secrets):

    * `target_database`, `temp_folder`, `migration_predecessor`,
      `migration_new`;
    * `child.claim`, `child.migrate.<state>`, `child.probe.<state>`,
      `child.drop`: `exit:<status>`, `timeout:confirmed`,
      `timeout:unconfirmed`, `not_started` or `raised` (untyped);
    * `migrate.<state>.direction` and `migrate.<state>.version`;
    * `state.<state>.check_count` and `state.<state>.check.<name>`
      (`permitted`, `refused:<code>` or `unexpected`), for the states
      the plan probes (`predecessor`, `up`, `down` and `up_again` by default);
    * only when not the default: `plan` (`down_refusal`),
      `migrate.<state>.expected` (`refusal`), `migrate.<state>.refusal`
      (`check_violation`, `untyped`, `target_refused` or `not_refused`),
      `runner.<step>.<state>` (`override`) and `probe.<state>.script` (the
      support-relative script path);
    * `cleanup.drop_attempted`, `cleanup.drop_mode` (`normal`: no `FORCE`,
      no connection termination), `cleanup.backends_before_drop` and
      `cleanup.database_absent_after_drop` (reported by the drop child, or
      `unreported`), `cleanup.drop_result`, `cleanup.temp_folder`
      (`removed` or `retained`) and `cleanup.temp_folder_retained_reason`
      (`unconfirmed_child`, `drop_failed`, `drop_receipt_invalid`,
      `evidence_incomplete` or `remove_failed`);
    * only when the drop child reported `drop_protocol` (the r7b drain,
      `drop_flow/1`): `cleanup.drop_protocol`, `cleanup.blocking_before_drop`,
      `cleanup.excluded_before_drop` and `cleanup.drain_attempts` (there,
      `cleanup.backends_before_drop` is the actual count, exact autovacuum
      workers included);
    * only with `:evidence_dir`: `evidence.claim` (`claimed`),
      `evidence.export` (`sealed` or `failed`) and, when sealed,
      `evidence.files` (the number of files the seal covers);
    * `outcome` (`ok` or `error`).

  The receipts are collected in memory and only returned: publishing them
  is the caller's job, after every cleanup decision has been made, so a
  failed write can fail the caller but never changes the cleanup.
  """
  def prove_with_receipts(opts) do
    previous = Process.put(@receipts, [])
    previous_children = Process.delete(@children)

    try do
      outcome = do_prove(opts)
      note("outcome", if(match?({:ok, _}, outcome), do: "ok", else: "error"))
      {outcome, Enum.reverse(Process.get(@receipts))}
    after
      restore(@receipts, previous)
      restore(@children, previous_children)
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, previous), do: Process.put(key, previous)

  defp do_prove(opts) do
    case config(opts) do
      {:ok, config} -> do_prove(opts, config)
      {:error, _} = error -> error
    end
  end

  defp do_prove(opts, config) do
    suffix = Keyword.fetch!(opts, :suffix)
    database = "sdr_agent_test" <> suffix
    runner = Keyword.fetch!(opts, :runner)
    versions = Keyword.fetch!(opts, :versions)
    tmp = Path.join(Keyword.fetch!(opts, :tmp_root), "sdr-witness-migration" <> suffix)
    note_target(database, tmp, versions)
    if config.plan_name != :continuity, do: note("plan", Atom.to_string(config.plan_name))

    with {:target, true} <- {:target, Regex.match?(@database, database)},
         {:evidence, :ok} <- {:evidence, claim_evidence(config.evidence)},
         {:tmp, :ok} <- {:tmp, File.mkdir(tmp)} do
      owned = %{tmp: tmp, database: nil}
      {outcome, owned} = run_owned(database, tmp, versions, {runner, config}, owned)
      finish(outcome, owned, database, {runner, config})
    else
      {:target, false} -> {:error, {:invalid_target, database}}
      {:evidence, {:error, reason}} -> {:error, {:evidence_not_claimed, config.evidence, reason}}
      {:tmp, {:error, reason}} -> {:error, {:tmp_not_claimed, tmp, reason}}
    end
  end

  ## Options (validated before anything is claimed)

  defp config(opts) do
    with :ok <- known_options(opts),
         {:ok, name, plan} <- plan(Keyword.get(opts, :plan, :continuity)),
         {:ok, probes} <- probes(Keyword.get(opts, :probe, default_probe()), plan),
         {:ok, runners} <- runners(Keyword.get(opts, :runners, %{}), plan),
         {:ok, evidence} <- evidence_dir(opts) do
      {:ok, %{plan_name: name, plan: plan, probes: probes, runners: runners, evidence: evidence}}
    end
  end

  defp known_options(opts) do
    case Keyword.keys(opts) -- @prove_options do
      [] -> :ok
      [key | _] -> {:error, {:invalid_option, key}}
    end
  end

  defp plan(:continuity) do
    {:ok, :continuity,
     [
       %{label: "predecessor", migrate: {"up", :predecessor}, probe?: true, expect: :ok},
       %{label: "up", migrate: {"up", :new}, probe?: true, expect: :ok},
       %{label: "down", migrate: {"down", :new}, probe?: true, expect: :ok},
       %{label: "up_again", migrate: {"up", :new}, probe?: true, expect: :ok}
     ]}
  end

  defp plan(:down_refusal) do
    {:ok, :down_refusal,
     [
       %{label: "up", migrate: {"up", :new}, probe?: true, expect: :ok},
       %{label: "down", migrate: {"down", :new}, probe?: false, expect: :refusal},
       %{label: "after_refusal", migrate: nil, probe?: true, expect: :ok}
     ]}
  end

  defp plan(_other), do: {:error, {:invalid_option, :plan}}

  defp default_probe, do: Path.join(@scripts, "probe.exs")

  defp probe_states(plan), do: for(%{probe?: true, label: label} <- plan, do: label)

  defp probes(probe, plan) when is_binary(probe) do
    if probe?(probe),
      do: {:ok, Map.new(probe_states(plan), &{&1, probe})},
      else: {:error, {:invalid_option, :probe}}
  end

  defp probes(%{} = probes, plan) do
    if Enum.sort(Map.keys(probes)) == Enum.sort(probe_states(plan)) and
         Enum.all?(Map.values(probes), &probe?/1),
       do: {:ok, probes},
       else: {:error, {:invalid_option, :probe}}
  end

  defp probes(_other, _plan), do: {:error, {:invalid_option, :probe}}

  defp probe?(path) do
    is_binary(path) and normalized_absolute?(path) and String.starts_with?(path, @support <> "/") and
      Path.relative_to(path, @support) in @probes and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp runners(%{} = runners, plan) do
    keys =
      for %{label: label} = step <- plan,
          {kind, present?} <- [migrate: step.migrate != nil, probe: step.probe?],
          present?,
          do: {kind, label}

    if Enum.all?(runners, fn {key, runner} -> key in keys and is_function(runner, 2) end),
      do: {:ok, runners},
      else: {:error, {:invalid_option, :runners}}
  end

  defp runners(_other, _plan), do: {:error, {:invalid_option, :runners}}

  # An absolute normalized path whose parent is an existing directory,
  # physically itself, and which is not, does not lie inside and does not
  # contain this checkout or the harness folder (lexically or physically).
  defp evidence_dir(opts) do
    case Keyword.fetch(opts, :evidence_dir) do
      :error ->
        {:ok, nil}

      {:ok, dir} ->
        if evidence_dir?(dir, harness_folders(opts) ++ checkout_roots()),
          do: {:ok, dir},
          else: {:error, {:invalid_option, :evidence_dir}}
    end
  end

  defp evidence_dir?(dir, reserved) do
    normalized_absolute?(dir) and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.dirname(dir))) and
      physical?(Path.dirname(dir)) and not Enum.any?(reserved, &shared?(dir, &1))
  end

  defp harness_folders(opts) do
    with suffix when is_binary(suffix) <- Keyword.get(opts, :suffix),
         root when is_binary(root) <- Keyword.get(opts, :tmp_root) do
      name = "sdr-witness-migration" <> suffix

      case physical_path(root) do
        {:ok, physical} -> [Path.join(root, name), Path.join(physical, name)]
        :error -> [Path.join(root, name)]
      end
    else
      _invalid -> []
    end
  end

  defp checkout_roots do
    case physical_path(@own_root) do
      {:ok, physical} -> [@own_root, physical]
      :error -> [@own_root]
    end
  end

  # Claimed by `File.mkdir/1` (an existing path is refused, never adopted)
  # and made private; it is never removed, by any cleanup.
  defp claim_evidence(nil), do: :ok

  defp claim_evidence(dir) do
    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      note("evidence.claim", "claimed")
      Process.put(@children, [])
      :ok
    end
  end

  defp run_owned(database, tmp, versions, {runner, config}, owned) do
    claim = run(runner, :claim, script("claim.exs", [database]), "claim")
    note("child.claim", child_outcome(claim))

    case claim do
      {:ok, _} ->
        owned = %{owned | database: database}
        {guarded_steps(database, tmp, versions, {runner, config}), owned}

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

  # The plan's states in order (continuity: predecessor -> new up -> new
  # down -> new up, probing after each).
  defp steps(database, tmp, versions, {runner, config}) do
    fixtures = Path.join(tmp, "fixtures.json")

    Enum.reduce_while(config.plan, {:ok, %{}}, fn %{label: label} = state, {:ok, states} ->
      with :ok <- migrate_step(state, database, versions, runner, config),
           {:ok, checks} <- probe_step(state, database, tmp, fixtures, runner, config) do
        {:cont, {:ok, if(checks, do: Map.put(states, label, checks), else: states)}}
      else
        {:timeout, _, _} = timeout -> {:halt, {:error, {:step_timeout, label, timeout}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp migrate_step(%{migrate: nil}, _database, _versions, _runner, _config), do: :ok

  defp migrate_step(state, database, versions, runner, config) do
    %{label: label, migrate: {direction, key}, expect: expect} = state
    version = Integer.to_string(Map.fetch!(versions, key))
    note("migrate.#{label}.direction", direction)
    note("migrate.#{label}.version", version)
    if expect == :refusal, do: note("migrate.#{label}.expected", "refusal")
    runner = step_runner(config, runner, {:migrate, label})
    args = script("migrate.exs", [database, direction, version])
    child = "migrate-#{direction}-#{version}"

    case expect do
      :ok ->
        case step(runner, :migrate, args, "child.migrate." <> label, child) do
          {:ok, _} -> :ok
          other -> other
        end

      :refusal ->
        refused_step(runner, args, label, child)
    end
  end

  # DB #2's `down`: only a confirmed nonzero exit (not the target refusal)
  # whose output carries the check_violation SQLSTATE line is the refusal.
  defp refused_step(runner, args, label, child) do
    outcome = run(runner, :migrate, args, child)
    note("child.migrate." <> label, child_outcome(outcome))

    case refusal_kind(outcome) do
      :check_violation ->
        note("migrate.#{label}.refusal", "check_violation")
        :ok

      reason when reason in [:not_refused, :target_refused, :untyped] ->
        note("migrate.#{label}.refusal", Atom.to_string(reason))
        {:error, {:down_refusal, reason, outcome}}

      :not_exited ->
        not_exited(outcome)
    end
  end

  # The refusal type of a down child's outcome (Codex 0c4bfabc Q2).
  defp refusal_kind({:ok, _out}), do: :not_refused
  defp refusal_kind({:exit, @target_refused, _out}), do: :target_refused

  defp refusal_kind({:exit, status, out})
       when is_integer(status) and status > 0 and is_binary(out),
       do: if(Regex.match?(@check_violation, out), do: :check_violation, else: :untyped)

  defp refusal_kind({:exit, _status, _out}), do: :untyped
  defp refusal_kind(_other), do: :not_exited

  # Today's typed handling of a child that never exited (timeout, not
  # started, raised).
  defp not_exited({:timeout, _, _} = timeout), do: timeout
  defp not_exited(other), do: {:error, {:migrate, other}}

  defp probe_step(%{probe?: false}, _database, _tmp, _fixtures, _runner, _config),
    do: {:ok, nil}

  defp probe_step(%{label: label}, database, tmp, fixtures, runner, config) do
    probe = Map.fetch!(config.probes, label)

    if probe != default_probe(),
      do: note("probe.#{label}.script", Path.relative_to(probe, @support))

    runner = step_runner(config, runner, {:probe, label})
    out = Path.join(tmp, label <> ".json")
    args = ["run", "--no-start", "--no-compile", "--no-deps-check", probe, database, label]

    with {:ok, _} <-
           step(
             runner,
             :probe,
             args ++ [fixtures, out],
             "child.probe." <> label,
             "probe-" <> label
           ),
         {:ok, json} <- read_json(out),
         {:ok, checks} <- probe_checks(json, database, label) do
      note_checks(label, checks)
      {:ok, checks}
    end
  end

  defp step_runner(config, runner, {kind, label} = key) do
    case Map.fetch(config.runners, key) do
      {:ok, override} ->
        note("runner.#{kind}.#{label}", "override")
        override

      :error ->
        runner
    end
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

  defp step(runner, name, args, receipt, child) do
    outcome = run(runner, name, args, child)
    note(receipt, child_outcome(outcome))

    case outcome do
      {:ok, out} -> {:ok, out}
      {:timeout, _, _} = timeout -> timeout
      other -> {:error, {name, other}}
    end
  end

  # A runner exception is reported as `{:raised, _}`, never re-raised, and
  # is always uncertain (`unconfirmed?/1`): it proves nothing about its child.
  # With an evidence directory, every child is recorded as `child`.
  defp run(runner, name, args, child) do
    outcome = call(runner, name, args)
    record_child(child, outcome)
    outcome
  end

  defp call(runner, name, args) do
    runner.(name, args)
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:raised, {kind, reason}}
  end

  # The evidence is exported on every path after the folder was claimed:
  # after the drop (so the drop child is in it) and before the folder is
  # removed; an unconfirmed child retains everything and is still exported.
  defp finish(outcome, owned, database, {runner, config}) do
    if Map.get(owned, :unconfirmed, false) or unconfirmed?(outcome) do
      note("cleanup.drop_attempted", "false")
      note("cleanup.temp_folder", "retained")
      note("cleanup.temp_folder_retained_reason", "unconfirmed_child")
      _exported = export(config.evidence, owned.tmp, config.plan)
      {:error, {:cleanup_skipped_unconfirmed_child, outcome, owned}}
    else
      case cleanup(owned, database, runner, config) do
        :ok -> outcome
        {:error, reason} -> {:error, {:cleanup_failed, reason, outcome}}
      end
    end
  end

  defp cleanup(owned, database, runner, config) do
    dropped =
      case owned.database do
        nil ->
          note("cleanup.drop_attempted", "false")
          :ok

        ^database ->
          drop(database, runner)
      end

    exported = export(config.evidence, owned.tmp, config.plan)

    with :ok <- dropped,
         :ok <- retained_unless_sealed(exported) do
      case File.rm_rf(owned.tmp) do
        {:ok, _} ->
          note("cleanup.temp_folder", "removed")
          :ok

        {:error, reason, path} ->
          note("cleanup.temp_folder", "retained")
          note("cleanup.temp_folder_retained_reason", "remove_failed")
          {:error, {:tmp_not_removed, path, reason}}
      end
    end
  end

  defp drop(database, runner) do
    note("cleanup.drop_attempted", "true")
    note("cleanup.drop_mode", "normal")
    outcome = run(runner, :drop, script("drop.exs", [database]), "drop")
    note("child.drop", child_outcome(outcome))
    note_drop_facts(outcome)

    case outcome do
      {:ok, out} ->
        # An exit-0 drop child counts only with exactly its two successful
        # facts (Codex 7ad3bd0 G2-F1); otherwise cleanup fails and the
        # folder (the evidence) is kept.
        case verify_drop_receipt(out) do
          {:ok, _facts} ->
            note("cleanup.drop_receipt", "valid")
            note("cleanup.drop_result", "ok")
            :ok

          {:error, reason} ->
            note("cleanup.drop_receipt", Atom.to_string(reason))
            note("cleanup.drop_result", "failed")
            note("cleanup.temp_folder", "retained")
            note("cleanup.temp_folder_retained_reason", "drop_receipt_invalid")
            {:error, {:drop, {:receipt_invalid, reason}}}
        end

      other ->
        note("cleanup.drop_receipt", "not_verified")
        note("cleanup.drop_result", "failed")
        note("cleanup.temp_folder", "retained")
        note("cleanup.temp_folder_retained_reason", "drop_failed")
        {:error, {:drop, other}}
    end
  end

  # Reached only after a successful drop (or none owed): an export that is
  # not sealed keeps the folder, the source of what was not exported.
  defp retained_unless_sealed(:ok), do: :ok

  defp retained_unless_sealed({:error, _} = error) do
    note("cleanup.temp_folder", "retained")
    note("cleanup.temp_folder_retained_reason", "evidence_incomplete")
    error
  end

  ## Evidence (`:evidence_dir`): recorded children, then one sealed export

  defp record_child(child, outcome) do
    case Process.get(@children) do
      children when is_list(children) ->
        number = children |> length() |> Kernel.+(1) |> Integer.to_string()
        name = String.pad_leading(number, 2, "0") <> "-" <> child
        Process.put(@children, [{name, child_outcome(outcome), child_output(outcome)} | children])

      nil ->
        :ok
    end
  end

  # Bounded output only; an exception or a typed refusal by its type only
  # (its text can carry anything, so it never reaches the evidence).
  defp child_output({:raised, %{__exception__: true} = exception}),
    do: "raised " <> inspect(exception.__struct__)

  defp child_output({:raised, {kind, _reason}}), do: "raised " <> inspect(kind)
  defp child_output({:not_started, {tag, _detail}}), do: "not_started " <> inspect(tag)
  defp child_output({:ok, out}) when is_binary(out), do: bounded(out)
  defp child_output({_kind, _status, out}) when is_binary(out), do: bounded(out)
  defp child_output(_other), do: ""

  defp bounded(out) when byte_size(out) <= @output_limit, do: out

  # 64 bytes are reserved for the marker (at most 45: its count has at most
  # 20 digits), so the whole record never exceeds `@output_limit`.
  defp bounded(out) do
    half = div(@output_limit - @marker_reserve, 2)
    elided = byte_size(out) - 2 * half

    binary_part(out, 0, half) <>
      "\n[... #{elided} bytes elided ...]\n" <> binary_part(out, byte_size(out) - half, half)
  end

  defp export(nil, _tmp, _plan), do: :ok

  defp export(dir, tmp, plan) do
    children =
      for {name, status, out} <- Enum.reverse(Process.get(@children, [])),
          entry <- [{"children/#{name}.status", status <> "\n"}, {"children/#{name}.out", out}],
          do: {:ok, entry}

    {entries, problems} =
      Enum.split_with(source_entries(tmp, plan) ++ children, &match?({:ok, _}, &1))

    entries = Enum.map(entries, &elem(&1, 1))
    written = write_entries(dir, entries)

    case Enum.map(problems, &elem(&1, 1)) ++ written do
      [] ->
        seal(dir, entries)

      incomplete ->
        note("evidence.export", "failed")
        {:error, {:evidence_incomplete, incomplete}}
    end
  end

  # Only the closed captures and results, as regular files (by lstat: a
  # symlink is never followed), read from the harness's own folder.
  defp source_entries(tmp, plan) do
    names = ["fixtures.json" | Enum.map(probe_states(plan), &(&1 <> ".json"))]

    case File.ls(tmp) do
      {:ok, files} -> Enum.map(Enum.sort(files), &source_entry(tmp, &1, names))
      {:error, reason} -> [{:error, {:source_unreadable, reason}}]
    end
  end

  defp source_entry(tmp, name, names) do
    path = Path.join(tmp, name)

    cond do
      name not in names ->
        {:error, {:unexpected_entry, name}}

      not match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) ->
        {:error, {:not_a_regular_file, name}}

      true ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, {"files/" <> name, bytes}}
          {:error, reason} -> {:error, {:unreadable, name, reason}}
        end
    end
  end

  # Every file is created exclusively (an existing path, symlink or not,
  # is refused) and made private; returns the problems.
  defp write_entries(dir, entries) do
    folders =
      for sub <- ~w(files children),
          result = private_dir(Path.join(dir, sub)),
          result != :ok,
          do: {sub, result}

    files =
      for {path, bytes} <- entries,
          result = private_file(Path.join(dir, path), bytes),
          result != :ok,
          do: {path, result}

    folders ++ files
  end

  defp private_dir(path) do
    with :ok <- File.mkdir(path), do: File.chmod(path, 0o700)
  end

  defp private_file(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, 0o600)
  end

  # The seal, written last: the sha256 of every exported file.
  defp seal(dir, entries) do
    sums =
      for {path, bytes} <- Enum.sort(entries), into: "" do
        "#{Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}  #{path}\n"
      end

    case private_file(Path.join(dir, "SHA256SUMS"), sums) do
      :ok ->
        note("evidence.files", Integer.to_string(length(entries)))
        note("evidence.export", "sealed")
        :ok

      {:error, reason} ->
        note("evidence.export", "failed")
        {:error, {:evidence_incomplete, [{"SHA256SUMS", reason}]}}
    end
  end

  ## The drop child's decision (pure; `drop.exs` injects the real effects)

  @drop_refused 5
  @drop_fact ~r/\A([a-z_]{1,32})=(\S+)\z/
  @drop_v1 ~w(backends_before_drop database_absent_after_drop)
  @drop_v2 ~w(backends_before_drop blocking_before_drop database_absent_after_drop drain_attempts
              drop_protocol excluded_before_drop)

  # The standing lane runner's r7b drain (#201, 425d7c9), and the plain
  # drop's own declared waits, outside the drain budget.
  @drain_budget_ms 10_000
  @drain_max_attempts 10
  @drain_pause_ms 1_000
  @drain_connect_ms 2_000
  @drain_slack_ms 500
  @drain_min_statement_ms 500
  @autovacuum "x6175746f76616375756d20776f726b6572"
  @backends_sql "with a as materialized (select backend_type as t from pg_stat_activity " <>
                  "where datname = $1), g as (select t, count(*) as n from a group by t) " <>
                  "select l from (select 0 as k, '' as o, 'backends total=' || " <>
                  "(select count(*) from a) || ' blocking=' || (select count(*) from a " <>
                  "where t collate \"C\" is distinct from 'autovacuum worker') || ' groups=' || " <>
                  "(select count(*) from g) as l union all select 1, v, 'type=' || v || " <>
                  "' count=' || n from (select case when t is null then 'N' else 'x' || " <>
                  "encode(convert_to(t, 'UTF8'), 'hex') end as v, n from g) e union all " <>
                  "select 2, '', 'end groups=' || (select count(*) from g)) z " <>
                  "order by k, o collate \"C\""
  @header_line ~r/\Abackends total=(0|[1-9]\d{0,8}) blocking=(0|[1-9]\d{0,8}) groups=(0|[1-9]\d{0,8})\z/
  @type_line ~r/\Atype=(N|x(?:[0-9a-f]{2})*) count=([1-9][0-9]{0,8})\z/
  @end_line ~r/\Aend groups=(0|[1-9]\d{0,8})\z/

  @doc "The exit status of a drop child that refused (`DROP-REFUSED <label>`)."
  def drop_refused, do: @drop_refused

  @doc """
  The drop child's fixed bounds: the standing lane runner's r7b drain (one
  monotonic budget per target, an attempt cap, the pause between
  observations, each observation's connect allowance, start-up slack and
  smallest statement/lock timeout), and the plain drop's and absence
  proof's own connect, statement and lock waits, outside that budget.
  """
  def drop_bounds do
    %{
      budget_ms: @drain_budget_ms,
      max_attempts: @drain_max_attempts,
      pause_ms: @drain_pause_ms,
      connect_timeout_ms: @drain_connect_ms,
      slack_ms: @drain_slack_ms,
      min_statement_ms: @drain_min_statement_ms,
      drop_connect_timeout_ms: 10_000,
      drop_statement_timeout_ms: 120_000,
      drop_lock_timeout_ms: 10_000
    }
  end

  @doc """
  The one statement of a drain observation (`$1` is the target's name):
  it reads `pg_stat_activity` once (a materialized CTE: one snapshot) for
  exactly that database and prints backend types and counts only (never
  query text, user, application, address or PID): `backends total=<T>
  blocking=<B> groups=<G>`, one `type=<N | x<hex of the type's UTF-8
  bytes>> count=<n>` line per distinct type in byte order (`N` is NULL),
  then `end groups=<G>`. `B` counts every backend whose type is distinct
  from exactly `'autovacuum worker'` (byte-wise, `COLLATE "C"`): NULL,
  empty, custom, case and whitespace variants and every other type block.
  The label is display text, not the server's internal autovacuum flag, so
  the plain, non-forced drop stays the final interlock.
  """
  def backends_sql, do: @backends_sql

  @doc """
  The checked reading of one observation's output lines: `{:ok, %{total:,
  blocking:, groups:, types: [{token, count}]}}` only for exactly the
  header, `G` distinct type lines and the end line, canonical numbers, type
  counts summing to the total and this reading's own blocking count (every
  type except exactly `x` + the hex of `autovacuum worker`) equal to the
  server's. Otherwise `{:error, why}`: `:not_text`, `:no_header`,
  `:bad_header`, `:bad_line`, `:repeated_type`, `:line_after_end`,
  `:no_end`, `:groups_mismatch`, `:total_mismatch` or `:blocking_mismatch`.
  Empty, truncated or unreconciled output is never a zero.
  """
  def parse_backends(lines) when is_list(lines) do
    with true <- Enum.all?(lines, &is_binary/1) || {:error, :not_text},
         [header | rest] <- lines,
         {:ok, counts} <- parse_header(header),
         {:ok, types, ended} <- parse_types(rest, [], nil),
         :ok <- reconcile(counts, types, ended) do
      {total, blocking, groups} = counts
      {:ok, %{total: total, blocking: blocking, groups: groups, types: Enum.reverse(types)}}
    else
      [] -> {:error, :no_header}
      {:error, _why} = error -> error
    end
  end

  def parse_backends(_other), do: {:error, :not_text}

  defp parse_header(line) do
    case Regex.run(@header_line, line) do
      [_, total, blocking, groups] ->
        {:ok, {String.to_integer(total), String.to_integer(blocking), String.to_integer(groups)}}

      nil ->
        {:error, :bad_header}
    end
  end

  defp parse_types([], _types, nil), do: {:error, :no_end}
  defp parse_types([], types, ended), do: {:ok, types, ended}

  defp parse_types([_line | _rest], _types, ended) when ended != nil,
    do: {:error, :line_after_end}

  defp parse_types([line | rest], types, nil) do
    case {Regex.run(@type_line, line), Regex.run(@end_line, line)} do
      {[_, token, count], nil} ->
        if List.keymember?(types, token, 0),
          do: {:error, :repeated_type},
          else: parse_types(rest, [{token, String.to_integer(count)} | types], nil)

      {nil, [_, groups]} ->
        parse_types(rest, types, String.to_integer(groups))

      _other ->
        {:error, :bad_line}
    end
  end

  defp reconcile({total, blocking, groups}, types, ended) do
    sum = Enum.sum(for {_token, n} <- types, do: n)
    own = Enum.sum(for {token, n} <- types, token != @autovacuum, do: n)

    cond do
      length(types) != groups or ended != groups -> {:error, :groups_mismatch}
      sum != total -> {:error, :total_mismatch}
      own != blocking -> {:error, :blocking_mismatch}
      true -> :ok
    end
  end

  @doc """
  The drop child's decision (protocol v2; Codex db034af6 Q6), with
  injected `effects`: `clock` (`{:ok, monotonic_ms}`; anything else is
  unreadable), `observe` (one bounded observation, given its statement and
  lock timeout in ms: `{:ok, lines}` or `{:error, reason}`), `pause`,
  `storage_down` (`:ok` or `{:error, reason}`), `count_present`
  (`{:ok, n}` or `{:error, reason}`) and `emit` (one line, must return
  `:ok`).

  **The drain** (the r7b protocol): one budget of `drop_bounds/0`'s
  `budget_ms`, fixed at the first clock read and never renewed. An
  observation starts only while its connect allowance, slack and smallest
  statement timeout fit the remaining budget, at most `max_attempts` times,
  a pause apart; one that ends at or after the deadline is late and not
  read. Each writes one `WM-DRAIN attempt=` line before its result counts.
  A valid observation with zero blocking backends is only eligible: one
  fresh clock read after its line must still be before the deadline. An
  unreadable or backward clock, a late, failed or malformed observation,
  an expired budget with blockers, a failed pause or any failed write
  refuses: no drop, no termination, a `WM-DRAIN retained: <label>` line.

  **Accepted**: `WM-DRAIN accepted attempt=<NN> final_check_elapsed_ms=<n>`
  and the facts `drop_protocol=2`, `backends_before_drop=<total>` (the
  actual count, autovacuum workers included: never zeroed),
  `blocking_before_drop=0`, `excluded_before_drop=<total>` and
  `drain_attempts=<n>`, all written before the plain `storage_down` (a
  failed write vetoes it); then the absence proof and
  `database_absent_after_drop=<bool>`. The drop and the proof keep their
  own declared waits, outside the drain budget: acceptance does not
  promise that they finish inside it.

  Returns `:ok` or `{:error, reason}`: `:clock_unreadable`,
  `:clock_backward`, `:deadline_expired`, `{:observation_failed, reason}`,
  `{:observation_malformed, why}`, `{:backends_present, blocking}`,
  `:pause_failed`, `:receipt_write_failed`, `{:drop_failed, reason}`,
  `{:absence_unproven, reason}` or `:database_present_after_drop`.
  """
  def drop_flow(effects) do
    with {:ok, accepted} <- drain(effects),
         :ok <- emit_all(effects, accepted_lines(accepted)),
         :ok <- storage_down(effects) do
      absence(effects)
    end
  end

  defp drain(effects) do
    result =
      with {:ok, t0} <- clock(effects, nil),
           :ok <- emit_line(effects, "WM-DRAIN " <> bounds_line()) do
        attempt(effects, %{t0: t0, deadline: t0 + @drain_budget_ms, prev: t0, blocking: 0}, 1)
      end

    with {:error, reason} <- result do
      _best_effort = effects.emit.("WM-DRAIN retained: " <> drop_refusal_label(reason))
      result
    end
  end

  defp bounds_line do
    "budget_ms=#{@drain_budget_ms} max_attempts=#{@drain_max_attempts} " <>
      "pause_ms=#{@drain_pause_ms} connect_timeout_ms=#{@drain_connect_ms} " <>
      "slack_ms=#{@drain_slack_ms} min_statement_ms=#{@drain_min_statement_ms}"
  end

  defp attempt(_effects, state, n) when n > @drain_max_attempts,
    do: {:error, {:backends_present, state.blocking}}

  defp attempt(effects, state, n) do
    with {:ok, now} <- clock(effects, state.prev),
         {:ok, ms} <- statement_bound(state.deadline - now) do
      # The observation first, then its end: a late one is never read.
      observed = effects.observe.(ms)
      ended = clock(effects, now)
      {result, detail, decision} = evaluate(observed, ended, state.deadline)
      line = attempt_line(n, state, {now, ended, ms}, {result, detail, decision})

      with :ok <- emit_line(effects, line) do
        decide(effects, decision, state, n)
      end
    end
  end

  # The statement and lock timeout an observation may start with.
  defp statement_bound(remaining) do
    ms = remaining - @drain_connect_ms - @drain_slack_ms
    if ms >= @drain_min_statement_ms, do: {:ok, ms}, else: {:error, :deadline_expired}
  end

  defp evaluate(_observed, {:error, reason}, _deadline),
    do: {"invalid", drop_refusal_label(reason), {:retain, reason}}

  defp evaluate(_observed, {:ok, ended}, deadline) when ended >= deadline,
    do: {"late", "deadline_expired", {:retain, :deadline_expired}}

  defp evaluate({:error, reason}, {:ok, _ended}, _deadline),
    do: {"failed", "observation_failed", {:retain, {:observation_failed, reason}}}

  defp evaluate({:ok, lines}, {:ok, ended}, deadline) do
    case parse_backends(lines) do
      {:ok, parsed} ->
        {"valid", parsed, valid_decision(parsed, ended, deadline)}

      {:error, why} ->
        {"malformed", Atom.to_string(why), {:retain, {:observation_malformed, why}}}
    end
  end

  defp evaluate(_other, {:ok, _ended}, _deadline),
    do: {"malformed", "not_text", {:retain, {:observation_malformed, :not_text}}}

  defp valid_decision(%{blocking: 0} = parsed, ended, _deadline), do: {:eligible, parsed, ended}

  defp valid_decision(%{blocking: blocking}, ended, deadline) do
    room = deadline - ended - @drain_pause_ms - @drain_connect_ms - @drain_slack_ms

    if room >= @drain_min_statement_ms,
      do: {:recheck, blocking, ended},
      else: {:retain, {:backends_present, blocking}}
  end

  # An eligible zero is accepted only by one fresh clock read, after its
  # parse and its line, still before the deadline fixed at t0.
  defp decide(effects, {:eligible, parsed, ended}, state, n) do
    case clock(effects, ended) do
      {:ok, final} when final < state.deadline ->
        {:ok, %{attempt: n, final_elapsed: final - state.t0, parsed: parsed}}

      {:ok, _late} ->
        {:error, :deadline_expired}

      {:error, _reason} = error ->
        error
    end
  end

  defp decide(effects, {:recheck, blocking, ended}, state, n) do
    case effects.pause.() do
      :ok -> attempt(effects, %{state | prev: ended, blocking: blocking}, n + 1)
      _failed -> {:error, :pause_failed}
    end
  end

  defp decide(_effects, {:retain, reason}, _state, _n), do: {:error, reason}

  defp clock(effects, prev) do
    case effects.clock.() do
      {:ok, ms} when is_integer(ms) and (prev == nil or ms >= prev) -> {:ok, ms}
      {:ok, ms} when is_integer(ms) -> {:error, :clock_backward}
      _unreadable -> {:error, :clock_unreadable}
    end
  end

  defp attempt_line(n, state, {now, ended, ms}, {result, detail, decision}) do
    end_elapsed =
      case ended do
        {:ok, t1} -> Integer.to_string(t1 - state.t0)
        {:error, _reason} -> ""
      end

    "WM-DRAIN attempt=#{pad2(n)} start_elapsed_ms=#{now - state.t0} " <>
      "end_elapsed_ms=#{end_elapsed} remaining_ms=#{state.deadline - now} " <>
      "statement_timeout_ms=#{ms} lock_timeout_ms=#{ms} result=#{result} " <>
      "#{detail_text(detail)} decision=#{elem(decision, 0)}"
  end

  defp detail_text(%{total: total, blocking: blocking, groups: groups, types: types}) do
    types = Enum.map_join(types, ",", fn {token, n} -> "#{token}:#{n}" end)
    "detail=[total=#{total} blocking=#{blocking} groups=#{groups}] types=[#{types}]"
  end

  defp detail_text(label), do: "detail=[#{label}] types=[]"

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp accepted_lines(%{attempt: n, final_elapsed: final, parsed: parsed}) do
    %{total: total, blocking: blocking} = parsed

    [
      "WM-DRAIN accepted attempt=#{pad2(n)} final_check_elapsed_ms=#{final}",
      "WM-CHILD drop_protocol=2",
      "WM-CHILD backends_before_drop=#{total}",
      "WM-CHILD blocking_before_drop=#{blocking}",
      "WM-CHILD excluded_before_drop=#{total - blocking}",
      "WM-CHILD drain_attempts=#{n}"
    ]
  end

  defp emit_all(effects, lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case emit_line(effects, line) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp emit_line(effects, line) do
    case effects.emit.(line) do
      :ok -> :ok
      _failed -> {:error, :receipt_write_failed}
    end
  end

  defp storage_down(effects) do
    case effects.storage_down.() do
      :ok -> :ok
      {:error, reason} -> {:error, {:drop_failed, reason}}
      other -> {:error, {:drop_failed, other}}
    end
  end

  defp absence(effects) do
    case effects.count_present.() do
      {:ok, present} when is_integer(present) and present >= 0 ->
        absence_fact(effects, present)

      {:error, reason} ->
        {:error, {:absence_unproven, reason}}

      other ->
        {:error, {:absence_unproven, other}}
    end
  end

  defp absence_fact(effects, present) do
    with :ok <- emit_line(effects, "WM-CHILD database_absent_after_drop=#{present == 0}") do
      if present == 0, do: :ok, else: {:error, :database_present_after_drop}
    end
  end

  @doc "The closed label a refusing drop child prints (`DROP-REFUSED <label>`)."
  def drop_refusal_label({:backends_present, _count}), do: "backends_present"
  def drop_refusal_label({:drop_failed, _reason}), do: "drop_failed"
  def drop_refusal_label(:database_present_after_drop), do: "database_present_after_drop"
  def drop_refusal_label(:receipt_write_failed), do: "receipt_write_failed"
  def drop_refusal_label(:clock_unreadable), do: "clock_unreadable"
  def drop_refusal_label(:clock_backward), do: "clock_backward"
  def drop_refusal_label(:deadline_expired), do: "deadline_expired"
  def drop_refusal_label(:pause_failed), do: "pause_failed"
  def drop_refusal_label({:observation_failed, _reason}), do: "observation_failed"
  def drop_refusal_label({:observation_malformed, _why}), do: "observation_malformed"
  def drop_refusal_label({:absence_unproven, _reason}), do: "absence_unproven"

  @doc """
  Strict check of an exit-0 drop child's output (its `WM-CHILD` facts),
  for either receipt version:

    * v1 (unchanged): exactly one `backends_before_drop=0` and one
      `database_absent_after_drop=true`;
    * v2 (`drop_flow/1`'s drain; additive): exactly one each of
      `drop_protocol=2`, `backends_before_drop`, `blocking_before_drop=0`,
      `excluded_before_drop` equal to `backends_before_drop` (only exact
      autovacuum workers remained, counted), `drain_attempts` (1 to 10) and
      `database_absent_after_drop=true`.

  `{:ok, facts}` or `{:error, reason}`, checked in this order:
  `:facts_malformed` (an unknown key, a bad line or value),
  `:facts_duplicate`, `:facts_missing` (neither version's exact key set),
  `:facts_contradictory` (any value other than the successful one).
  """
  def verify_drop_receipt(output) when is_binary(output) do
    lines = for [_, fact] <- Regex.scan(~r/^WM-CHILD (.*)$/m, output), do: fact
    parsed = Enum.map(lines, &parse_drop_fact/1)
    keys = for {:ok, key, _value} <- parsed, do: key
    facts = Map.new(for {:ok, key, value} <- parsed, do: {key, value})

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, :facts_malformed}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :facts_duplicate}

      Enum.sort(keys) not in [@drop_v1, @drop_v2] ->
        {:error, :facts_missing}

      successful_drop_facts?(facts) ->
        {:ok, facts}

      true ->
        {:error, :facts_contradictory}
    end
  end

  def verify_drop_receipt(_output), do: {:error, :facts_missing}

  defp parse_drop_fact(fact) do
    case Regex.run(@drop_fact, fact) do
      [_, key, value] -> if valid_drop_fact?(key, value), do: {:ok, key, value}, else: :error
      nil -> :error
    end
  end

  defp successful_drop_facts?(%{"drop_protocol" => "2"} = facts) do
    facts["blocking_before_drop"] == "0" and
      facts["backends_before_drop"] == facts["excluded_before_drop"] and
      facts["database_absent_after_drop"] == "true"
  end

  defp successful_drop_facts?(facts),
    do: facts["backends_before_drop"] == "0" and facts["database_absent_after_drop"] == "true"

  ## Receipts (closed keys; closed or synthetic values only)

  defp note(key, value) when is_binary(key) and is_binary(value) do
    case Process.get(@receipts) do
      receipts when is_list(receipts) -> Process.put(@receipts, [{key, value} | receipts])
      nil -> :ok
    end

    :ok
  end

  defp note_target(database, tmp, versions) do
    note("target_database", database)
    note("temp_folder", tmp)

    with %{new: new, predecessor: predecessor} <- versions do
      note("migration_predecessor", Integer.to_string(predecessor))
      note("migration_new", Integer.to_string(new))
    end
  end

  defp note_checks(label, checks) do
    note("state.#{label}.check_count", Integer.to_string(map_size(checks)))

    for {name, result} <- Enum.sort(checks) do
      name = if Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, name), do: name, else: "invalid_name"
      note("state.#{label}.check.#{name}", closed_result(result))
    end
  end

  defp closed_result(result) do
    if Regex.match?(~r/\A(permitted|refused:[a-z_]{1,64})\z/, result),
      do: result,
      else: "unexpected"
  end

  @doc false
  # The closed label of one child outcome (never its output).
  def child_outcome({:ok, _out}), do: "exit:0"
  def child_outcome({:exit, status, _out}) when is_integer(status), do: "exit:#{status}"
  def child_outcome({:timeout, :confirmed, _out}), do: "timeout:confirmed"
  def child_outcome({:timeout, :unconfirmed, _out}), do: "timeout:unconfirmed"
  def child_outcome({:not_started, _reason}), do: "not_started"
  def child_outcome({:raised, _reason}), do: "raised"
  def child_outcome(_other), do: "unknown"

  # The drop child's own facts (`WM-CHILD <key>=<value>` lines), each
  # validated to its closed form; `unreported` when absent or malformed.
  # The protocol v2 facts are recorded only beside a reported
  # `drop_protocol` (additive: a v1 receipt records exactly as before).
  defp note_drop_facts(outcome) do
    output =
      case outcome do
        {:ok, out} when is_binary(out) -> out
        {:exit, _status, out} when is_binary(out) -> out
        {:timeout, _confirmed, out} when is_binary(out) -> out
        _other -> ""
      end

    facts = drop_facts(output)
    note("cleanup.backends_before_drop", Map.get(facts, "backends_before_drop", "unreported"))

    note(
      "cleanup.database_absent_after_drop",
      Map.get(facts, "database_absent_after_drop", "unreported")
    )

    if Map.has_key?(facts, "drop_protocol") do
      for key <- ~w(drop_protocol blocking_before_drop excluded_before_drop drain_attempts),
          do: note("cleanup." <> key, Map.get(facts, key, "unreported"))
    end

    :ok
  end

  @doc false
  # Parses the drop child's closed facts from its output.
  def drop_facts(output) when is_binary(output) do
    for [_, key, value] <-
          Regex.scan(
            ~r/^WM-CHILD ([a-z_]{1,32})=(\S+)$/m,
            output
          ),
        valid_drop_fact?(key, value),
        into: %{},
        do: {key, value}
  end

  defp valid_drop_fact?("backends_before_drop", value),
    do: Regex.match?(~r/\A[0-9]{1,6}\z/, value)

  defp valid_drop_fact?("database_absent_after_drop", value), do: value in ["true", "false"]
  defp valid_drop_fact?("drop_protocol", value), do: value == "2"

  defp valid_drop_fact?(count, value) when count in ~w(blocking_before_drop excluded_before_drop),
    do: Regex.match?(~r/\A(0|[1-9][0-9]{0,5})\z/, value)

  defp valid_drop_fact?("drain_attempts", value), do: Regex.match?(~r/\A([1-9]|10)\z/, value)
  defp valid_drop_fact?(_unknown, _value), do: false

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

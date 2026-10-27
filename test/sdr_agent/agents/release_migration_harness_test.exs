defmodule SdrAgent.Agents.ReleaseMigrationHarnessTest do
  @moduledoc """
  C2* slice S3 RED-6 (S3 plan r2 section 9; Codex 7a9c7eea sequencing items
  2-4): the parameterization of `SdrAgent.WitnessMigration.Harness` that the
  T-S4 release-migration campaign (`SdrAgent.Agents.ReleaseMigrationTest`,
  `:external`) needs, with stubbed children only. Statically, every
  lifecycle call goes through a recording stub and every runner built from
  the real `checked_runner` has an unusable executable, and this module
  checks out no Repo connection (any Repo use fails loudly). At run time,
  `no_ports!/1` traces the ports newly opened by this process and its
  descendants during each wrapped call (an OS child, a socket or a new
  connection made from here) and fails on one; it does not observe ports or
  connections that other, already-running processes hold. It is
  `async: false` because the port trace is global.

  The contract these tests pin (GREEN-6 implements it; the existing defaults
  and `SdrAgent.Agents.WitnessMigrationHarnessTest` stay unchanged):

    * `versions/2` with `:migration_suffix` (default today's
      `"_v4_mismatch_lineage.exs"`; shape `_<a-z0-9_>.exs`), refusing a bad
      suffix or an unknown option as `{:error, {:invalid_option, key}}`;
    * `prove/1` and `prove_with_receipts/1` options, all optional, each
      refused as `{:error, {:invalid_option, key}}` before anything is
      claimed (no runner call, no temporary folder), as is every unknown
      option (there is no force, adoption or alternate-target option):
        - `:probe`: one script for every probe state, or a map naming
          exactly the plan's probe states; only `witness_migration/probe.exs`
          (the default) and `release_migration/{baseline,probe,demo}.exs`,
          as absolute normalized paths of existing regular files;
        - `:runners`: `%{{:migrate | :probe, state} => runner}` for the
          plan's own steps; the claim and the drop always run on `:runner`;
        - `:plan`: `:continuity` (default: predecessor, up, down, up_again)
          or `:down_refusal` (up, a `down` that must be refused with
          `check_violation`, then the `after_refusal` probe);
    * receipts gain only `runner.<step>.<state>=override`,
      `probe.<state>.script=<support-relative path>` (non-default scripts),
      `plan=down_refusal`, `migrate.down.expected=refusal` and
      `migrate.down.refusal=check_violation|untyped|target_refused|not_refused`;
      a default run's receipts are byte-identical to today's;
    * a per-root build (Codex 0c4bfabc R6-1, R6-2): `checked_runner/5`
      with `toolchain: :inherit` (exactly today's `checked_runner/4`, whose
      default is unchanged) or `toolchain: :root`. In root mode the child's
      environment is `SdrAgent.ChildEnv.port([], set)` (ChildEnv's policy
      unchanged: only its base names are inherited, its secrets always
      removed) with `set` from the pure `root_child_env/4`: the four Mix
      roots re-rooted under `root` by the pure `root_toolchain/3`, which
      refuses a root that is, contains or lies inside the own root;
      `ERL_LIBS` set to its value only when every entry is an immutable
      `/nix/store/<hash>-<name>` path, explicitly removed when unset, and
      otherwise refused (`:code_path_unapproved`); explicit removal of the
      other code-path names (`ERL_FLAGS`, `ERL_AFLAGS`, `ERL_ZFLAGS`,
      `ELIXIR_ERL_OPTIONS`, `MIX_PATH`, `MIX_ARCHIVES`, `MIX_EXS`,
      `MIX_BUILD_PATH`); `MIX_ENV=test` and the partition. Before the
      executable check and before any spawn it refuses, as
      `{:not_started, reason}` and in this order: a root that is absent, not
      a directory or not physically itself (a symlink at the root or at any
      ancestor: `:root_unusable`); a root physically equal to, inside or
      containing the own root (`:root_shared`); the `root_child_env/4`
      refusals; a re-rooted Mix root with any non-directory or symlinked
      component below the root (`:toolchain_unusable`). Confinement is
      physical, never a string-prefix test. `PATH` is not a BEAM code path
      (the pinned Elixir wrapper puts its own Erlang first) and stays a
      ChildEnv base name.

  RED classification: the `versions/2`, `root_toolchain/3`,
  `root_child_env/4` and `checked_runner/5` tests go through `harness/2`,
  which reports an absent
  function as `{:not_implemented, name, arity}` (structural); the release
  script effect test is structural (scaffolds). The `prove` option tests
  fail on their semantic assertions (today the options are ignored). Tests
  named `control:` pass now and must keep passing.

  The release probes' history tests (Codex ed67bbfe M1, CPU only) load the
  campaign's shared module `release_migration/common.exs` (definitions
  only: requiring it runs nothing) and call its pure checks on synthetic
  captures: a changed or missing captured event, or an unaccounted append,
  must be refused even when the chain is valid.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.WitnessMigration.Harness

  @root Path.expand("../../..", __DIR__)
  @support Path.join(@root, "test/support")
  @wm Path.join(@support, "witness_migration")
  @rm Path.join(@support, "release_migration")
  @migrations Path.join(@root, "priv/repo/migrations")
  @external Path.join(@root, "test/sdr_agent/agents/release_migration_test.exs")
  @prefix ["run", "--no-start", "--no-compile", "--no-deps-check"]
  @s3_suffix "_c2star_s3_demo_exception_release.exs"
  @lineage %{new: 20_261_021_101_539, predecessor: 20_261_016_052_435}
  @s3 %{new: 20_261_027_081_524, predecessor: 20_261_026_033_738}
  @continuity ~w(predecessor up down up_again)
  @mix_roots ~w(MIX_HOME HEX_HOME MIX_DEPS_PATH MIX_BUILD_ROOT)
  @valid_drop_output "WM-CHILD backends_before_drop=0\nWM-CHILD database_absent_after_drop=true\n"
  @refused_down """
  VALIDATED sdr_agent_test_wm0000000000
  STARTING after validation
  ** (Postgrex.Error) ERROR 23514 (check_violation) check constraint "model_result_releases_disposition" of relation "model_result_releases" is violated by some row
  """

  # The release probes' shared module (definitions only; nothing runs).
  setup_all do
    Code.require_file("common.exs", @rm)
    :ok
  end

  ## Fixtures

  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-rm-harness" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # A temporary root reached without any symlink (macOS's /tmp and /var
  # are symlinks), for roots that must be physically themselves.
  defp physical_tmp_root do
    root = physical!(tmp_root())
    assert physical!(root) == root
    root
  end

  # The physical path: every symlinked component resolved, by lstat and
  # readlink only (no process).
  defp physical!(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn part, acc ->
      next = Path.join(acc, part)

      case File.read_link(next) do
        {:ok, target} -> physical!(Path.expand(target, acc))
        {:error, _not_a_link} -> next
      end
    end)
  end

  defp owned_tmp(root, sfx), do: Path.join(root, "sdr-witness-migration" <> sfx)

  defp recorder do
    {:ok, log} = Agent.start_link(fn -> [] end)
    log
  end

  defp calls(log), do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&describe/1)

  # A recording runner named `name`: logs `{name, step, args}`; `answer`
  # gets the described call and returns `:default`, an outcome, or a
  # zero-arity function run in place of the child (to raise, throw or exit).
  # A successful probe writes a valid result where a real child would.
  defp stub(log, name, database, answer \\ fn _call -> :default end) do
    fn step, args ->
      Agent.update(log, &[{name, step, args} | &1])

      outcome =
        case answer.(describe({name, step, args})) do
          :default -> default_answer(step)
          fun when is_function(fun, 0) -> fun.()
          outcome -> outcome
        end

      write_probe(step, outcome, args, database)
      outcome
    end
  end

  defp default_answer(:drop), do: {:ok, @valid_drop_output}
  defp default_answer(_step), do: {:ok, ""}

  defp write_probe(:probe, {:ok, _}, args, database) do
    [label, _fixtures, out] = Enum.take(args, -3)
    body = %{"database" => database, "label" => label, "checks" => %{"stub" => "permitted"}}
    File.write!(out, JSON.encode!(body))
  end

  defp write_probe(_step, _outcome, _args, _database), do: :ok

  # `{name, :claim | :drop}`, `{name, :migrate, direction, version}` or
  # `{name, :probe, label, script relative to test/support}`.
  defp describe({name, step, args}) do
    case {step, Enum.drop(args, length(@prefix))} do
      {:migrate, [_script, _database, direction, version]} ->
        {name, :migrate, direction, version}

      {:probe, [script, _database, label, _fixtures, _out]} ->
        {name, :probe, label, Path.relative_to(script, @support)}

      {step, _rest} ->
        {name, step}
    end
  end

  defp opts(sfx, runner, root, versions, extra \\ []),
    do: [suffix: sfx, tmp_root: root, versions: versions, runner: runner] ++ extra

  defp prove(opts), do: no_ports!(fn -> Harness.prove(opts) end)
  defp prove_with_receipts(opts), do: no_ports!(fn -> Harness.prove_with_receipts(opts) end)

  # Calls a harness function only when it exists (RED: structural).
  defp harness(function, args) do
    Code.ensure_loaded(Harness)

    if function_exported?(Harness, function, length(args)),
      do: apply(Harness, function, args),
      else: {:not_implemented, function, length(args)}
  end

  ## The executor proof: no port opened by this process or its descendants

  defp no_ports!(fun) do
    {result, opened} = ports_opened(fun)
    assert opened == [], "a port was opened (child, socket or connection): #{inspect(opened)}"
    result
  end

  # Runs `fun` while tracing every new port and every process this test
  # process spawns (transitively); returns `{result, [{opener, driver}]}`
  # for the ports opened by this process or one of its descendants.
  defp ports_opened(fun) do
    test = self()
    tracer = spawn_link(fn -> trace_loop([], []) end)
    :erlang.trace(test, true, [:procs, :set_on_spawn, {:tracer, tracer}])
    :erlang.trace(:new_ports, true, [:ports, {:tracer, tracer}])

    result =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      after
        :erlang.trace(:new_ports, false, [:ports])
        :erlang.trace(test, false, [:procs, :set_on_spawn])
      end

    opened = drain(tracer, test)

    case result do
      {:ok, value} -> {value, opened}
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp drain(tracer, test) do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000
    send(tracer, {:drain, self(), test})
    assert_receive {:opened, opened}, 5_000
    opened
  end

  defp trace_loop(opens, edges) do
    receive do
      {:trace, parent, :spawn, child, _mfa} ->
        trace_loop(opens, [{parent, child} | edges])

      {:trace, _port, :open, opener, driver} ->
        trace_loop([{opener, driver} | opens], edges)

      {:drain, from, test} ->
        family = family(MapSet.new([test]), edges)
        send(from, {:opened, for({o, d} <- Enum.reverse(opens), o in family, do: {o, d})})

      _other ->
        trace_loop(opens, edges)
    end
  end

  defp family(set, edges) do
    grown =
      Enum.reduce(edges, set, fn {parent, child}, acc ->
        if MapSet.member?(acc, parent), do: MapSet.put(acc, child), else: acc
      end)

    if MapSet.equal?(grown, set), do: set, else: family(grown, edges)
  end

  # The four Mix roots of this test's environment, each relative to the
  # project root (the devenv shell the runner and CI use sets all four
  # inside it).
  defp own_mix_roots! do
    for name <- @mix_roots do
      value = System.get_env(name)
      assert is_binary(value), "#{name} must be set (the devenv shell sets it)"
      assert String.starts_with?(value, @root <> "/"), "#{name} must lie inside #{@root}"
      {name, Path.relative_to(value, @root)}
    end
  end

  # A synthetic checkout under `base` with real directories for the four
  # Mix roots, except `except`, which is a symlink to a real directory.
  defp build_tree!(base, except \\ nil) do
    for {name, rel} <- own_mix_roots!() do
      path = Path.join(base, rel)

      if name == except do
        File.mkdir_p!(Path.dirname(path))
        real = Path.join(base, "real-" <> String.downcase(name))
        File.mkdir_p!(real)
        :ok = File.ln_s(real, path)
      else
        File.mkdir_p!(path)
      end
    end

    base
  end

  # Runs a root-mode runner built for `root` once; every executable here is
  # unusable, so no child can start whatever the code under test does.
  defp root_mode(root, exe) do
    runner = harness(:checked_runner, [exe, suffix(), root, 1_000, [toolchain: :root]])
    assert is_function(runner, 2), "#{root}: #{inspect(runner)}"
    no_ports!(fn -> runner.(:claim, ["run"]) end)
  end

  ## Controls: the executor proof itself

  describe "control: the port trace" do
    # An unconnected inet driver instance: a port, but no OS process, no
    # socket and no connection.
    test "it sees a port this process opens and one a process it spawned opens" do
      {task, opened} =
        ports_opened(fn ->
          port = :erlang.open_port({:spawn_driver, ~c"tcp_inet"}, [:binary])
          Port.close(port)

          task =
            Task.async(fn ->
              child = :erlang.open_port({:spawn_driver, ~c"tcp_inet"}, [:binary])
              Port.close(child)
            end)

          Task.await(task)
          task.pid
        end)

      assert MapSet.new(opened) == MapSet.new([{self(), :tcp_inet}, {task, :tcp_inet}])
      assert length(opened) == 2
      assert ports_opened(fn -> :quiet end) == {:quiet, []}
    end
  end

  ## Controls: defaults identical to today

  describe "control: defaults are today's" do
    test "versions/1 on the real migrations still selects the lineage migration" do
      assert Harness.versions(@migrations) == {:ok, @lineage}
    end

    test "every default command, in order, with today's scripts and arguments" do
      sfx = suffix()
      database = "sdr_agent_test" <> sfx
      root = tmp_root()
      tmp = owned_tmp(root, sfx)
      log = recorder()

      assert {:ok, _} = prove(opts(sfx, stub(log, :primary, database), root, @lineage))

      probe = fn label ->
        @prefix ++
          [Path.join(@wm, "probe.exs"), database, label, Path.join(tmp, "fixtures.json")] ++
          [Path.join(tmp, label <> ".json")]
      end

      migrate = fn direction, version ->
        @prefix ++
          [Path.join(@wm, "migrate.exs"), database, direction, Integer.to_string(version)]
      end

      assert log |> Agent.get(& &1) |> Enum.reverse() == [
               {:primary, :claim, @prefix ++ [Path.join(@wm, "claim.exs"), database]},
               {:primary, :migrate, migrate.("up", @lineage.predecessor)},
               {:primary, :probe, probe.("predecessor")},
               {:primary, :migrate, migrate.("up", @lineage.new)},
               {:primary, :probe, probe.("up")},
               {:primary, :migrate, migrate.("down", @lineage.new)},
               {:primary, :probe, probe.("down")},
               {:primary, :migrate, migrate.("up", @lineage.new)},
               {:primary, :probe, probe.("up_again")},
               {:primary, :drop, @prefix ++ [Path.join(@wm, "drop.exs"), database]}
             ]
    end

    test "a completed default run's receipts are exactly today's, in order" do
      sfx = suffix()
      database = "sdr_agent_test" <> sfx
      root = tmp_root()

      assert {{:ok, _}, receipts} =
               prove_with_receipts(
                 opts(sfx, stub(recorder(), :primary, database), root, @lineage)
               )

      state = fn label, direction, version ->
        [
          {"migrate.#{label}.direction", direction},
          {"migrate.#{label}.version", Integer.to_string(version)},
          {"child.migrate.#{label}", "exit:0"},
          {"child.probe.#{label}", "exit:0"},
          {"state.#{label}.check_count", "1"},
          {"state.#{label}.check.stub", "permitted"}
        ]
      end

      assert receipts ==
               [
                 {"target_database", database},
                 {"temp_folder", owned_tmp(root, sfx)},
                 {"migration_predecessor", "20261016052435"},
                 {"migration_new", "20261021101539"},
                 {"child.claim", "exit:0"}
               ] ++
                 state.("predecessor", "up", @lineage.predecessor) ++
                 state.("up", "up", @lineage.new) ++
                 state.("down", "down", @lineage.new) ++
                 state.("up_again", "up", @lineage.new) ++
                 [
                   {"cleanup.drop_attempted", "true"},
                   {"cleanup.drop_mode", "normal"},
                   {"child.drop", "exit:0"},
                   {"cleanup.backends_before_drop", "0"},
                   {"cleanup.database_absent_after_drop", "true"},
                   {"cleanup.drop_receipt", "valid"},
                   {"cleanup.drop_result", "ok"},
                   {"cleanup.temp_folder", "removed"},
                   {"outcome", "ok"}
                 ]
    end

    test "explicit default options run exactly the default commands and receipts" do
      sfx = suffix()
      database = "sdr_agent_test" <> sfx
      root = tmp_root()

      run = fn extra ->
        log = recorder()

        result =
          prove_with_receipts(opts(sfx, stub(log, :primary, database), root, @lineage, extra))

        {result, calls(log)}
      end

      default = run.([])
      explicit = run.(probe: Path.join(@wm, "probe.exs"), runners: %{}, plan: :continuity)
      assert {{{:ok, _}, _receipts}, _calls} = default
      assert explicit == default
    end
  end

  ## versions/2 and :migration_suffix (structural until GREEN-6)

  describe "versions/2: the :migration_suffix option" do
    test "the default suffix is today's; the S3 suffix selects S3 and its immediate predecessor" do
      today = Harness.versions(@migrations)
      assert harness(:versions, [@migrations, []]) == today

      assert harness(:versions, [@migrations, [migration_suffix: "_v4_mismatch_lineage.exs"]]) ==
               today

      assert harness(:versions, [@migrations, [migration_suffix: @s3_suffix]]) == {:ok, @s3}
    end

    test "in a fixture directory: absent, selected, and ambiguous like today" do
      dir = tmp_root()
      s3 = [migration_suffix: @s3_suffix]

      for file <- ~w(20261012214848_r0_07a_result_release.exs
                     20261016052435_c2_02b2b_resolution_check.exs
                     20261021101539_v4_mismatch_lineage.exs
                     20261026033738_ash_functions_v7_extensions_1.exs),
          do: File.write!(Path.join(dir, file), "")

      assert harness(:versions, [dir, s3]) == {:error, :migration_absent}
      File.write!(Path.join(dir, "20261027081524_c2star_s3_demo_exception_release.exs"), "")
      assert harness(:versions, [dir, s3]) == {:ok, @s3}
      assert harness(:versions, [dir, []]) == {:ok, @lineage}

      assert {:error, {:migration_ambiguous, [_, _]}} =
               harness(:versions, [dir, [migration_suffix: "_release.exs"]])
    end

    test "a malformed suffix and an unknown option are refused" do
      for bad <- [
            "",
            "_.exs",
            "_v4_mismatch_lineage",
            "v4_mismatch_lineage.exs",
            "_x.ex",
            "_X.exs",
            "_x/y.exs",
            "/_x.exs",
            "_../x.exs",
            "_x*.exs",
            "_x y.exs",
            "_x\n.exs",
            nil,
            :x,
            ~c"_x.exs"
          ] do
        assert harness(:versions, [@migrations, [migration_suffix: bad]]) ==
                 {:error, {:invalid_option, :migration_suffix}},
               inspect(bad)
      end

      for key <- [:suffix, :force, :dir] do
        assert harness(:versions, [@migrations, [{key, "_x.exs"}]]) ==
                 {:error, {:invalid_option, key}},
               inspect(key)
      end
    end
  end

  ## :probe (behavioural: today the option is ignored)

  describe "the :probe option" do
    test "one release script replaces the probe at every state; nothing else changes" do
      sfx = suffix()
      log = recorder()
      probe = Path.join(@rm, "probe.exs")

      assert {{:ok, _}, receipts} =
               prove_with_receipts(
                 opts(sfx, stub(log, :primary, "sdr_agent_test" <> sfx), tmp_root(), @s3,
                   probe: probe
                 )
               )

      assert calls(log) == [
               {:primary, :claim},
               {:primary, :migrate, "up", "20261026033738"},
               {:primary, :probe, "predecessor", "release_migration/probe.exs"},
               {:primary, :migrate, "up", "20261027081524"},
               {:primary, :probe, "up", "release_migration/probe.exs"},
               {:primary, :migrate, "down", "20261027081524"},
               {:primary, :probe, "down", "release_migration/probe.exs"},
               {:primary, :migrate, "up", "20261027081524"},
               {:primary, :probe, "up_again", "release_migration/probe.exs"},
               {:primary, :drop}
             ]

      facts = Map.new(receipts)

      for state <- @continuity,
          do: assert(facts["probe.#{state}.script"] == "release_migration/probe.exs", state)
    end

    test "a map names one script per probe state (DB #1: the baseline at predecessor)" do
      sfx = suffix()
      log = recorder()

      probe = %{
        "predecessor" => Path.join(@rm, "baseline.exs"),
        "up" => Path.join(@rm, "probe.exs"),
        "down" => Path.join(@rm, "probe.exs"),
        "up_again" => Path.join(@rm, "probe.exs")
      }

      assert {:ok, _} =
               prove(
                 opts(sfx, stub(log, :primary, "sdr_agent_test" <> sfx), tmp_root(), @s3,
                   probe: probe
                 )
               )

      assert for({_, :probe, label, script} <- calls(log), do: {label, script}) == [
               {"predecessor", "release_migration/baseline.exs"},
               {"up", "release_migration/probe.exs"},
               {"down", "release_migration/probe.exs"},
               {"up_again", "release_migration/probe.exs"}
             ]
    end

    test "any other probe is refused before anything is claimed" do
      tmp = tmp_root()
      outside = Path.join(tmp, "probe.exs")
      File.write!(outside, "")
      link = Path.join(tmp, "linked_probe.exs")
      :ok = File.ln_s(Path.join(@rm, "probe.exs"), link)
      valid = Map.new(@continuity, &{&1, Path.join(@rm, "probe.exs")})

      for {label, bad} <- [
            {"relative", "test/support/release_migration/probe.exs"},
            {"not normalized", Path.join(@rm, "../release_migration/probe.exs")},
            {"absent", Path.join(@rm, "absent.exs")},
            {"the claim child", Path.join(@wm, "claim.exs")},
            {"the migrate child", Path.join(@wm, "migrate.exs")},
            {"the drop child", Path.join(@wm, "drop.exs")},
            {"the shared module", Path.join(@wm, "common.exs")},
            {"outside the support tree", outside},
            {"a symlink", link},
            {"a directory", @rm},
            {"an atom", :probe},
            {"nil", nil},
            {"a map without up_again", Map.delete(valid, "up_again")},
            {"a map with a foreign state", Map.put(valid, "after_refusal", valid["up"])},
            {"a map with a bad script", Map.put(valid, "down", Path.join(@wm, "drop.exs"))}
          ] do
        assert_refused_before_claim(:probe, probe: bad, label: label)
      end
    end
  end

  ## :runners (behavioural): per-step build roots, ownership, typed exits

  describe "the :runners option" do
    test "DB #1: OLD writes and verifies, NEW verifies up, OLD verifies down, NEW up_again" do
      sfx = suffix()
      database = "sdr_agent_test" <> sfx
      log = recorder()
      old = stub(log, :old, database)

      runners = %{
        {:migrate, "predecessor"} => old,
        {:probe, "predecessor"} => old,
        {:probe, "down"} => old
      }

      probe = %{
        "predecessor" => Path.join(@rm, "baseline.exs"),
        "up" => Path.join(@rm, "probe.exs"),
        "down" => Path.join(@rm, "probe.exs"),
        "up_again" => Path.join(@rm, "probe.exs")
      }

      assert {{:ok, states}, receipts} =
               prove_with_receipts(
                 opts(sfx, stub(log, :new, database), tmp_root(), @s3,
                   runners: runners,
                   probe: probe
                 )
               )

      assert Enum.sort(Map.keys(states)) == Enum.sort(@continuity)

      assert calls(log) == [
               {:new, :claim},
               {:old, :migrate, "up", "20261026033738"},
               {:old, :probe, "predecessor", "release_migration/baseline.exs"},
               {:new, :migrate, "up", "20261027081524"},
               {:new, :probe, "up", "release_migration/probe.exs"},
               {:new, :migrate, "down", "20261027081524"},
               {:old, :probe, "down", "release_migration/probe.exs"},
               {:new, :migrate, "up", "20261027081524"},
               {:new, :probe, "up_again", "release_migration/probe.exs"},
               {:new, :drop}
             ]

      overrides = for {"runner." <> key, value} <- receipts, do: {key, value}

      assert overrides == [
               {"migrate.predecessor", "override"},
               {"probe.predecessor", "override"},
               {"probe.down", "override"}
             ]
    end

    test "every command keeps the owned database, a closed script and the fixed mix prefix" do
      for plan <- [:continuity, :down_refusal] do
        sfx = suffix()
        database = "sdr_agent_test" <> sfx
        log = recorder()

        answer = fn
          {_, :migrate, "down", _} when plan == :down_refusal -> {:exit, 1, @refused_down}
          _call -> :default
        end

        old = stub(log, :old, database, answer)
        override = if plan == :continuity, do: {:probe, "down"}, else: {:probe, "after_refusal"}

        result =
          prove(
            opts(sfx, stub(log, :new, database, answer), tmp_root(), @s3,
              plan: plan,
              probe: Path.join(@rm, "demo.exs"),
              runners: %{override => old}
            )
          )

        assert match?({:ok, _}, result), "#{plan}: #{inspect(result)}"

        scripts =
          ~w(witness_migration/claim.exs witness_migration/migrate.exs witness_migration/drop.exs
             release_migration/demo.exs)

        entries = log |> Agent.get(& &1) |> Enum.reverse()
        assert [{:new, :claim, _} | _] = entries
        assert {:new, :drop, _} = List.last(entries)
        assert Enum.count(entries, &(elem(&1, 0) == :old)) == 1, inspect(plan)

        for {_name, step, args} <- entries do
          assert Enum.take(args, 4) == @prefix, "#{step}: #{inspect(args)}"
          [script, target | _] = Enum.drop(args, 4)
          assert Path.relative_to(script, @support) in scripts, "#{step}: #{script}"
          assert target == database, "#{step}: the owned database only"
        end
      end
    end

    test "claim and drop are never overridable, and only the plan's steps are" do
      fun = fn _step, _args -> flunk("an override runner must never be called") end

      for {label, runners, plan} <- [
            {"claim", %{claim: fun}, :continuity},
            {"drop", %{drop: fun}, :continuity},
            {"claim at a state", %{{:claim, "predecessor"} => fun}, :continuity},
            {"drop at a state", %{{:drop, "up"} => fun}, :continuity},
            {"a foreign state", %{{:probe, "after_refusal"} => fun}, :continuity},
            {"an unknown state", %{{:probe, "nope"} => fun}, :continuity},
            {"an atom state", %{{:migrate, :up} => fun}, :continuity},
            {"no probe at down_refusal's down", %{{:probe, "down"} => fun}, :down_refusal},
            {"no migrate after the refusal", %{{:migrate, "after_refusal"} => fun},
             :down_refusal},
            {"no predecessor in down_refusal", %{{:migrate, "predecessor"} => fun},
             :down_refusal},
            {"not a runner", %{{:probe, "up"} => :runner}, :continuity},
            {"a one-argument function", %{{:probe, "up"} => fn _args -> :ok end}, :continuity},
            {"a list, not a map", [{{:probe, "up"}, fun}], :continuity},
            {"not a map", :all, :continuity}
          ] do
        assert_refused_before_claim(:runners, runners: runners, plan: plan, label: label)
      end
    end

    test "a step on an override runner keeps today's typed exits and cleanup on :runner" do
      for {label, outcome, expected, cleaned?} <- [
            {"target refused", {:exit, 4, "REFUSED target_not_configured"},
             {:error, {:probe, {:exit, 4, "REFUSED target_not_configured"}}}, true},
            {"not started", {:not_started, {:root_unusable, "/absent"}},
             {:error, {:probe, {:not_started, {:root_unusable, "/absent"}}}}, true},
            {"confirmed timeout", {:timeout, :confirmed, ""},
             {:error, {:step_timeout, "predecessor", {:timeout, :confirmed, ""}}}, true},
            {"unconfirmed timeout", {:timeout, :unconfirmed, ""}, :retained, false},
            {"raised", fn -> raise "synthetic override failure" end, :retained, false}
          ] do
        sfx = suffix()
        database = "sdr_agent_test" <> sfx
        root = tmp_root()
        log = recorder()
        old = stub(log, :old, database, fn _call -> outcome end)

        result =
          prove(
            opts(sfx, stub(log, :new, database), root, @s3,
              runners: %{{:probe, "predecessor"} => old}
            )
          )

        assert calls(log) |> Enum.take(3) == [
                 {:new, :claim},
                 {:new, :migrate, "up", "20261026033738"},
                 {:old, :probe, "predecessor", "witness_migration/probe.exs"}
               ],
               label

        if cleaned? do
          assert result == expected, "#{label}: #{inspect(result)}"
          assert List.last(calls(log)) == {:new, :drop}, label
          refute File.exists?(owned_tmp(root, sfx)), label
        else
          assert match?({:error, {:cleanup_skipped_unconfirmed_child, _, _}}, result),
                 "#{label}: #{inspect(result)}"

          refute Enum.any?(calls(log), &match?({_, :drop}, &1)), label
          assert File.dir?(owned_tmp(root, sfx)), label
        end
      end
    end
  end

  ## :plan :down_refusal (behavioural): DB #2's typed refusal and full rollback probe

  describe "the :down_refusal plan" do
    test "up, probe, a down refused with check_violation, the after_refusal probe, then drop" do
      sfx = suffix()
      database = "sdr_agent_test" <> sfx
      root = tmp_root()
      log = recorder()

      answer = fn
        {_, :migrate, "down", _} -> {:exit, 1, @refused_down}
        _call -> :default
      end

      assert {{:ok, states}, receipts} =
               prove_with_receipts(
                 opts(sfx, stub(log, :new, database, answer), root, @s3,
                   plan: :down_refusal,
                   probe: Path.join(@rm, "demo.exs")
                 )
               )

      assert Enum.sort(Map.keys(states)) == ~w(after_refusal up)

      assert calls(log) == [
               {:new, :claim},
               {:new, :migrate, "up", "20261027081524"},
               {:new, :probe, "up", "release_migration/demo.exs"},
               {:new, :migrate, "down", "20261027081524"},
               {:new, :probe, "after_refusal", "release_migration/demo.exs"},
               {:new, :drop}
             ]

      facts = Map.new(receipts)

      assert Map.take(facts, ~w(plan migrate.down.expected child.migrate.down
                               migrate.down.refusal child.probe.after_refusal
                               cleanup.drop_result cleanup.temp_folder outcome)) == %{
               "plan" => "down_refusal",
               "migrate.down.expected" => "refusal",
               "child.migrate.down" => "exit:1",
               "migrate.down.refusal" => "check_violation",
               "child.probe.after_refusal" => "exit:0",
               "cleanup.drop_result" => "ok",
               "cleanup.temp_folder" => "removed",
               "outcome" => "ok"
             }

      refute Map.has_key?(facts, "child.migrate.predecessor")
      refute File.exists?(owned_tmp(root, sfx))
    end

    test "a down that is not the typed refusal fails, is cleaned up and is never probed" do
      for {label, outcome, reason} <- [
            {"down succeeded", {:ok, "migrated down"}, :not_refused},
            {"another failure", {:exit, 1, "** (RuntimeError) boom"}, :untyped},
            {"another SQLSTATE",
             {:exit, 1, "** (Postgrex.Error) ERROR 23505 (unique_violation) duplicate key"},
             :untyped},
            {"the code not at a line start",
             {:exit, 1, "note: ERROR 23514 (check_violation) quoted"}, :untyped},
            {"the target refusal", {:exit, 4, "REFUSED target_not_configured"}, :target_refused}
          ] do
        assert_down_classified(label, outcome, reason)
      end
    end

    # Codex 0c4bfabc Q2: only an anchored check_violation line with a
    # confirmed integer nonzero exit (never the target refusal) is the refusal.
    test "the refusal classifier: no status-0, malformed-status or lookalike line counts" do
      line =
        "** (Postgrex.Error) ERROR 23514 (check_violation) check constraint " <>
          ~s|"model_result_releases_disposition" of relation "model_result_releases" | <>
          "is violated by some row"

      assert @refused_down =~ line, "the same line the positive case uses"

      for {label, outcome} <- [
            {"status 0", {:exit, 0, line}},
            {"a negative status", {:exit, -1, line}},
            {"a string status", {:exit, "1", line}},
            {"a float status", {:exit, 1.0, line}},
            {"output that is not a binary", {:exit, 1, [line]}},
            {"an indented line", {:exit, 1, "  " <> line}},
            {"a quoted line", {:exit, 1, "\"" <> line <> "\""}},
            {"the line inside other text", {:exit, 1, "STARTING " <> line}},
            {"another exception module",
             {:exit, 1, "** (Ecto.Error) ERROR 23514 (check_violation) check constraint x"}},
            {"no space before the condition",
             {:exit, 1, "** (Postgrex.Error) ERROR 23514(check_violation) check constraint x"}},
            {"nothing after the condition",
             {:exit, 1, "** (Postgrex.Error) ERROR 23514 (check_violation)"}}
          ] do
        assert_down_classified(label, outcome, :untyped)
      end
    end

    test "a down child that never started, timed out or raised keeps today's typed handling" do
      for {label, outcome, expected} <- [
            {"not started", {:not_started, {:executable_unusable, "/absent"}},
             {:cleaned, {:error, {:migrate, {:not_started, {:executable_unusable, "/absent"}}}}}},
            {"confirmed timeout", {:timeout, :confirmed, ""},
             {:cleaned, {:error, {:step_timeout, "down", {:timeout, :confirmed, ""}}}}},
            {"unconfirmed timeout", {:timeout, :unconfirmed, ""}, :retained},
            {"raised", fn -> exit(:synthetic) end, :retained}
          ] do
        sfx = suffix()
        database = "sdr_agent_test" <> sfx
        root = tmp_root()
        log = recorder()

        answer = fn
          {_, :migrate, "down", _} -> outcome
          _call -> :default
        end

        result =
          prove(
            opts(sfx, stub(log, :new, database, answer), root, @s3,
              plan: :down_refusal,
              probe: Path.join(@rm, "demo.exs")
            )
          )

        assert Enum.take(calls(log), 4) == [
                 {:new, :claim},
                 {:new, :migrate, "up", "20261027081524"},
                 {:new, :probe, "up", "release_migration/demo.exs"},
                 {:new, :migrate, "down", "20261027081524"}
               ],
               label

        refute Enum.any?(calls(log), &match?({_, :probe, "after_refusal", _}, &1)), label

        case expected do
          {:cleaned, error} ->
            assert result == error, "#{label}: #{inspect(result)}"
            assert List.last(calls(log)) == {:new, :drop}, label

          :retained ->
            assert match?({:error, {:cleanup_skipped_unconfirmed_child, _, _}}, result),
                   "#{label}: #{inspect(result)}"

            refute Enum.any?(calls(log), &match?({_, :drop}, &1)), label
            assert File.dir?(owned_tmp(root, sfx)), label
        end
      end
    end
  end

  ## Unknown options (behavioural): no force, adoption or alternate target

  describe "option validation" do
    test "an unknown option or plan is refused before anything is claimed" do
      for {key, value} <- [
            force: true,
            adopt: true,
            database: "sdr_agent_dev",
            migration_suffix: @s3_suffix,
            drop_mode: :force,
            runner_env: []
          ] do
        assert_refused_before_claim(key, [{key, value}, label: inspect(key)])
      end

      for plan <- [:up_only, "continuity", nil],
          do: assert_refused_before_claim(:plan, plan: plan, label: inspect(plan))
    end
  end

  # DB #2 with `outcome` as the `down` child's: a typed `down_refusal`
  # error with `reason`, recorded, cleaned up, and never probed after.
  defp assert_down_classified(label, outcome, reason) do
    sfx = suffix()
    database = "sdr_agent_test" <> sfx
    root = tmp_root()
    log = recorder()

    answer = fn
      {_, :migrate, "down", _} -> outcome
      _call -> :default
    end

    {result, receipts} =
      prove_with_receipts(
        opts(sfx, stub(log, :new, database, answer), root, @s3,
          plan: :down_refusal,
          probe: Path.join(@rm, "demo.exs")
        )
      )

    assert result == {:error, {:down_refusal, reason, outcome}}, "#{label}: #{inspect(result)}"
    assert Map.new(receipts)["migrate.down.refusal"] == Atom.to_string(reason), label

    assert calls(log) == [
             {:new, :claim},
             {:new, :migrate, "up", "20261027081524"},
             {:new, :probe, "up", "release_migration/demo.exs"},
             {:new, :migrate, "down", "20261027081524"},
             {:new, :drop}
           ],
           label

    refute File.exists?(owned_tmp(root, sfx)), label
  end

  defp assert_refused_before_claim(key, extra) do
    {label, extra} = Keyword.pop(extra, :label)
    sfx = suffix()
    root = tmp_root()
    log = recorder()

    result =
      prove(opts(sfx, stub(log, :primary, "sdr_agent_test" <> sfx), root, @s3, extra))

    assert result == {:error, {:invalid_option, key}}, "#{label}: #{inspect(result)}"
    assert calls(log) == [], "#{label}: nothing runs"
    refute File.exists?(owned_tmp(root, sfx)), "#{label}: nothing is claimed"
  end

  ## Per-root build (structural until GREEN-6; Codex 0c4bfabc R6-1, R6-2):
  ## root_toolchain/3, root_child_env/4 and checked_runner/5

  @own "/w/own"
  @tag_dir "elixir-1.20.4-otp-29.0.5"
  @hex_lib "/nix/store/xb3qnl7ai8s4dy3vxarypx86v0k5ymiv-hex-2.5.1/lib/erlang/lib/"
  @code_path_removed ~w(ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS MIX_PATH
                        MIX_ARCHIVES MIX_EXS MIX_BUILD_PATH)
  @child_env_secrets ~w(SDR_AUDIT_ANCHOR_PRIVATE_KEY SDR_WEBHOOK_HMAC_KEY SECRET_KEY_BASE
                        TOKEN_SIGNING_SECRET DATABASE_URL)

  defp devenv(root) do
    state = root <> "/.devenv/state"

    %{
      "MIX_HOME" => state <> "/mix/" <> @tag_dir,
      "HEX_HOME" => state <> "/hex",
      "MIX_DEPS_PATH" => state <> "/deps/" <> @tag_dir,
      "MIX_BUILD_ROOT" => state <> "/build/" <> @tag_dir
    }
  end

  describe "root_toolchain/3 (pure, lexical)" do
    test "another root re-roots each Mix root under itself and returns nothing else" do
      env = Map.merge(devenv(@own), %{"ERL_LIBS" => @hex_lib, "PATH" => "/usr/bin"})
      base = for name <- @mix_roots, do: {name, devenv("/w/base")[name]}

      assert harness(:root_toolchain, [@own, "/w/base", env]) == {:ok, base}
    end

    test "a root that is, contains or lies inside the own root is refused as shared" do
      for root <- [@own, "/w/own/sub", "/w/own/.devenv", "/w", "/"] do
        assert harness(:root_toolchain, [@own, root, devenv(@own)]) ==
                 {:error, {:root_shared, root}},
               root
      end

      # A sibling that only shares a name prefix is another checkout.
      sibling = for name <- @mix_roots, do: {name, devenv("/w/own2")[name]}
      assert harness(:root_toolchain, [@own, "/w/own2", devenv(@own)]) == {:ok, sibling}
    end

    test "a Mix root outside the own root, or unset, is refused: no fallback to the parent's" do
      for {label, value} <- [
            {"elsewhere", "/elsewhere/build"},
            {"a sibling prefix", "/w/own2/.devenv/state/build/x"},
            {"the root itself", "/w/own"},
            {"relative", ".devenv/state/build/x"},
            {"traversal", "/w/own/../base/.devenv/state/build/x"},
            {"empty", ""}
          ] do
        env = Map.put(devenv(@own), "MIX_BUILD_ROOT", value)

        assert harness(:root_toolchain, [@own, "/w/base", env]) ==
                 {:error, {:toolchain_outside_root, "MIX_BUILD_ROOT"}},
               label
      end

      for name <- @mix_roots do
        assert harness(:root_toolchain, [@own, "/w/base", Map.delete(devenv(@own), name)]) ==
                 {:error, {:toolchain_unset, name}},
               name
      end
    end

    test "the target root must be an absolute, normalized path" do
      for root <- ["", "base", "/w/base/../own", "/w/base/", nil] do
        assert harness(:root_toolchain, [@own, root, devenv(@own)]) ==
                 {:error, {:root_invalid, root}},
               inspect(root)
      end
    end
  end

  describe "root_child_env/4 (pure): the root-mode child's ChildEnv set" do
    test "four re-rooted Mix roots, the approved ERL_LIBS, code-path removals, test env, partition" do
      sfx = suffix()

      env =
        Map.merge(devenv(@own), %{
          "ERL_LIBS" => @hex_lib,
          "ERL_AFLAGS" => "-kernel shell_history enabled",
          "MIX_PATH" => "/w/own/_build/test/lib/sdr_agent/ebin",
          "PATH" => "/usr/bin:/bin"
        })

      result = harness(:root_child_env, [@own, "/w/base", sfx, env])
      assert match?({:ok, set} when is_list(set), result), inspect(result)
      {:ok, set} = result
      assert length(set) == length(Enum.uniq_by(set, &elem(&1, 0))), "one entry per name"

      expected =
        devenv("/w/base")
        |> Map.merge(%{"ERL_LIBS" => @hex_lib, "MIX_ENV" => "test", "MIX_TEST_PARTITION" => sfx})
        |> Map.merge(Map.new(@code_path_removed, &{&1, nil}))

      assert Map.new(set) == expected
    end

    test "an unset ERL_LIBS is removed explicitly; several approved store entries are kept" do
      other = "/nix/store/0npp3qpr68phld0d5jffn13si9qngvk7-erlang-29.0.5/lib/erlang/lib"

      for {label, erl_libs, expected} <- [
            {"unset", nil, nil},
            {"two store entries", @hex_lib <> ":" <> other, @hex_lib <> ":" <> other}
          ] do
        env = if erl_libs, do: Map.put(devenv(@own), "ERL_LIBS", erl_libs), else: devenv(@own)
        result = harness(:root_child_env, [@own, "/w/base", suffix(), env])
        assert match?({:ok, set} when is_list(set), result), "#{label}: #{inspect(result)}"
        {:ok, set} = result
        assert List.keyfind(set, "ERL_LIBS", 0) == {"ERL_LIBS", expected}, label
      end
    end

    test "an ERL_LIBS entry that is not an immutable Nix store path is refused" do
      for {label, erl_libs} <- [
            {"NEW's build", "/w/own/.devenv/state/build/#{@tag_dir}/test/lib"},
            {"NEW's checkout", "/w/own/lib"},
            {"the OLD root", "/w/base/lib"},
            {"another checkout", "/w/other/.devenv/state/deps/#{@tag_dir}"},
            {"approved, then NEW", @hex_lib <> ":/w/own/lib"},
            {"a mutable Nix profile", "/nix/var/nix/profiles/default/lib/erlang/lib"},
            {"a store traversal",
             "/nix/store/xb3qnl7ai8s4dy3vxarypx86v0k5ymiv-hex-2.5.1/../../../w/own/lib"},
            {"a store path without a hash", "/nix/store/hex-2.5.1/lib/erlang/lib"},
            {"relative", "lib/erlang/lib"},
            {"an empty entry", @hex_lib <> "::" <> @hex_lib},
            {"empty", ""}
          ] do
        env = Map.put(devenv(@own), "ERL_LIBS", erl_libs)

        assert harness(:root_child_env, [@own, "/w/base", suffix(), env]) ==
                 {:error, {:code_path_unapproved, "ERL_LIBS"}},
               label
      end
    end

    test "the root_toolchain/3 refusals come first" do
      bad = Map.put(devenv(@own), "ERL_LIBS", "/w/own/lib")

      assert harness(:root_child_env, [@own, @own, suffix(), bad]) ==
               {:error, {:root_shared, @own}}

      assert harness(:root_child_env, [@own, "/w/base", suffix(), Map.delete(bad, "MIX_HOME")]) ==
               {:error, {:toolchain_unset, "MIX_HOME"}}
    end

    # The final overrides through ChildEnv's unchanged policy, over this
    # test's real environment (CPU only: nothing is spawned).
    test "the final child env: intended roots, test env, partition, removals, secrets, nothing from NEW" do
      sfx = suffix()
      base = "/w/base"
      env = System.get_env()
      result = harness(:root_child_env, [@root, base, sfx, env])
      assert match?({:ok, set} when is_list(set), result), inspect(result)
      {:ok, set} = result
      final = Map.new(SdrAgent.ChildEnv.cmd([], set))

      for {name, rel} <- own_mix_roots!(),
          do: assert(final[name] == Path.join(base, rel), name)

      assert {final["MIX_ENV"], final["MIX_TEST_PARTITION"]} == {"test", sfx}

      for name <- @code_path_removed ++ @child_env_secrets,
          do: assert(Map.fetch(final, name) == {:ok, nil}, name)

      assert Map.fetch(final, "ERL_LIBS") == {:ok, env["ERL_LIBS"]}

      for {name, value} <- env, String.contains?(value, @root) do
        assert Map.has_key?(final, name), "#{name} would be inherited from NEW's checkout"
        refute String.contains?(final[name] || "", @root), name
      end
    end
  end

  describe "checked_runner/5 refuses before spawning (every executable here is unusable)" do
    test "toolchain: :inherit is checked_runner/4" do
      root = tmp_root()
      exe = Path.join(root, "missing")
      runner = harness(:checked_runner, [exe, suffix(), root, 1_000, [toolchain: :inherit]])
      assert is_function(runner, 2), inspect(runner)

      assert no_ports!(fn -> runner.(:claim, ["run"]) end) ==
               {:not_started, {:executable_unusable, exe}}
    end

    test "toolchain: :root refuses a missing or symlinked root, or one without its Mix roots" do
      tmp = physical_tmp_root()
      exe = Path.join(tmp, "missing")
      absent = Path.join(tmp, "absent")
      link = Path.join(tmp, "link")
      :ok = File.ln_s(@root, link)
      empty = Path.join(tmp, "empty")
      :ok = File.mkdir(empty)
      symlinked_build = build_tree!(Path.join(tmp, "symlinked"), "MIX_BUILD_ROOT")

      for {label, root, expected} <- [
            {"absent", absent, {:not_started, {:root_unusable, absent}}},
            {"a symlink", link, {:not_started, {:root_unusable, link}}},
            {"no Mix roots", empty, {:not_started, {:toolchain_unusable, "MIX_HOME"}}},
            {"a symlinked build root", symlinked_build,
             {:not_started, {:toolchain_unusable, "MIX_BUILD_ROOT"}}}
          ] do
        assert root_mode(root, exe) == expected, label
      end
    end

    test "a symlink at any ancestor of the root is refused, though every directory below is real" do
      tmp = physical_tmp_root()
      exe = Path.join(tmp, "missing")
      outside = Path.join(tmp, "outside")
      build_tree!(Path.join(outside, "base"))
      :ok = File.ln_s(outside, Path.join(tmp, "alias"))
      aliased = Path.join([tmp, "alias", "base"])
      assert File.dir?(Path.join(aliased, ".devenv")), "the alias reaches a real build tree"

      assert root_mode(aliased, exe) == {:not_started, {:root_unusable, aliased}}

      # The same directory reached physically is a legitimate root.
      assert root_mode(Path.join(outside, "base"), exe) ==
               {:not_started, {:executable_unusable, exe}}
    end

    test "a root physically shared with the own checkout is refused: equal, inside, containing, aliased" do
      assert physical!(@root) == @root, "the own checkout is reached physically"
      tmp = physical_tmp_root()
      exe = Path.join(tmp, "missing")
      inside = Path.join(@root, "test")
      containing = Path.dirname(@root)
      :ok = File.ln_s(@root, Path.join(tmp, "new"))
      :ok = File.ln_s(containing, Path.join(tmp, "checkouts"))
      leaf_alias = Path.join(tmp, "new")
      ancestor_alias = Path.join([tmp, "checkouts", Path.basename(@root)])

      for {label, root, reason} <- [
            {"the own checkout", @root, :root_shared},
            {"inside it", inside, :root_shared},
            {"containing it", containing, :root_shared},
            {"an alias of it", leaf_alias, :root_unusable},
            {"it through an aliased ancestor", ancestor_alias, :root_unusable}
          ] do
        assert root_mode(root, exe) == {:not_started, {reason, root}}, label
      end
    end

    test "a root whose build tree is aliased into the own checkout is refused" do
      tmp = physical_tmp_root()
      exe = Path.join(tmp, "missing")
      root = Path.join(tmp, "borrowed")
      :ok = File.mkdir(root)
      :ok = File.ln_s(Path.join(@root, ".devenv"), Path.join(root, ".devenv"))
      assert File.dir?(Path.join(root, ".devenv/state")), "the alias reaches NEW's state"

      assert root_mode(root, exe) == {:not_started, {:toolchain_unusable, "MIX_HOME"}}
    end

    test "a legitimate physical baseline root passes the root checks and still needs the executable" do
      tmp = physical_tmp_root()
      exe = Path.join(tmp, "missing")
      base = build_tree!(Path.join(tmp, "base"))

      assert root_mode(base, exe) == {:not_started, {:executable_unusable, exe}}
    end

    test "an unknown option or toolchain mode is refused when the runner is built" do
      root = tmp_root()
      exe = Path.join(root, "missing")

      # The message is not part of the contract (assert_raise/3 would pin it).
      for extra <- [[force: true], [toolchain: :parent], [toolchain: "root"], [build_root: root]] do
        built =
          try do
            harness(:checked_runner, [exe, suffix(), root, 1_000, extra])
          rescue
            error in ArgumentError -> error
          end

        assert match?(%ArgumentError{}, built), "#{inspect(extra)}: #{inspect(built)}"
      end
    end
  end

  ## The release scripts and the external campaign (structural / controls)

  describe "release scripts and the external campaign" do
    test "each release script validates its target first, then performs its probe" do
      for script <- ~w(baseline.exs probe.exs demo.exs) do
        source = File.read!(Path.join(@rm, script))
        calls = script |> top_level_calls() |> Enum.reject(&(&1 in [:require_file, :argv]))
        assert hd(calls) in [:validate_target!, :start!], "#{script}: #{inspect(calls)}"
        after_validation = calls |> tl() |> Enum.reject(&(&1 in [:puts, :halt]))
        assert after_validation != [], "#{script}: structural RED (scaffold): #{inspect(calls)}"
        refute source =~ "NOT-IMPLEMENTED", "#{script}: still a RED-6 scaffold"
      end
    end

    test "control: no child script has a shell, a forced drop or a connection kill" do
      shells = [{System, :cmd}, {System, :shell}, {Port, :open}, {:os, :cmd}]
      forbidden = ~r/\bFORCE\b|pg_terminate_backend|pg_cancel_backend|DROP\s+DATABASE/i

      for dir <- [@wm, @rm], file <- File.ls!(dir), String.ends_with?(file, ".exs") do
        ast = dir |> Path.join(file) |> File.read!() |> Code.string_to_quoted!()

        {_, found} =
          Macro.prewalk(ast, [], fn
            {{:., _, [{:__aliases__, _, mod}, fun]}, _, _} = node, acc ->
              {node, [{Module.concat(mod), fun} | acc]}

            {{:., _, [mod, fun]}, _, _} = node, acc when is_atom(mod) ->
              {node, [{mod, fun} | acc]}

            node, acc when is_binary(node) ->
              {node, if(node =~ forbidden, do: [{:string, node} | acc], else: acc)}

            node, acc ->
              {node, acc}
          end)

        offending = Enum.filter(found, &(&1 in shells or match?({:string, _}, &1)))
        assert offending == [], "#{file}: #{inspect(offending)}"
      end
    end

    test "control: the campaign module is :external and the default suite excludes it" do
      assert :external in Keyword.get(ExUnit.configuration(), :exclude, [])

      {:defmodule, _, [_name, [do: {:__block__, _, statements}]]} =
        @external |> File.read!() |> Code.string_to_quoted!()

      assert Enum.any?(statements, &match?({:@, _, [{:moduletag, _, [:external]}]}, &1))
    end
  end

  ## Release probes: preserved history, not only a valid chain (pure, CPU only;
  ## Codex ed67bbfe M1)

  @preserved %{
    "chain_valid" => "permitted",
    "captured_events_unchanged" => "permitted",
    "appends_accounted" => "permitted"
  }

  # Calls a pure check of the release probes' shared module.
  defp probes(function, args), do: apply(SdrAgent.ReleaseMigration, function, args)

  defp history_event(id, sequence, type) do
    %{
      "id" => id,
      "tenant_id" => "tenant-a",
      "sequence" => sequence,
      "event_type" => type,
      "event_hash" => "hash-#{id}",
      "row_sha256" => "row-#{id}"
    }
  end

  defp history_capture do
    %{
      "events" => [
        history_event("e1", 1, "agents.run.created"),
        history_event("e2", 2, "model.result.demo_exception"),
        history_event("e3", 3, "audit.access.chain_verify")
      ],
      "heads" => [%{"tenant_id" => "tenant-a", "last_sequence" => 3, "last_event_hash" => "x"}]
    }
  end

  describe "release probes: preserved history, not only a valid chain (pure)" do
    test "the captured history plus only the probes' own appends is preserved" do
      capture = history_capture()

      current =
        capture["events"] ++
          [
            history_event("e4", 4, "audit.access.chain_verify"),
            history_event("e5", 5, "system.provenance.recorded")
          ]

      assert probes(:history_checks, [capture, current, "permitted"]) == @preserved
      assert probes(:history_checks, [capture, capture["events"], "permitted"]) == @preserved
    end

    test "a changed or missing captured event is refused although the chain is valid" do
      capture = history_capture()
      [e1, e2, e3] = capture["events"]

      for {label, current, expected} <- [
            {"the demo event's row rewritten", [e1, %{e2 | "row_sha256" => "rewritten"}, e3],
             "refused:event_changed"},
            {"the demo event re-hashed", [e1, %{e2 | "event_hash" => "other"}, e3],
             "refused:event_changed"},
            {"the demo event moved", [e1, %{e2 | "sequence" => 7}, e3], "refused:event_changed"},
            {"the demo event's type changed", [e1, %{e2 | "event_type" => "x"}, e3],
             "refused:event_changed"},
            {"the demo event missing", [e1, e3], "refused:event_missing"},
            {"the demo event under another id", [e1, %{e2 | "id" => "e2b"}, e3],
             "refused:event_missing"}
          ] do
        result = probes(:history_checks, [capture, current, "permitted"])
        assert result["chain_valid"] == "permitted", label
        assert result["captured_events_unchanged"] == expected, "#{label}: #{inspect(result)}"
        refute result == @preserved, label
      end
    end

    test "an append that is not one of the probes' own is refused although the chain is valid" do
      capture = history_capture()

      for {label, extra} <- [
            {"a new demo event after the head",
             history_event("e4", 4, "model.result.demo_exception")},
            {"a new release event after the head",
             history_event("e4", 4, "model.result.withheld")},
            {"an uncaptured event at the head's sequence",
             history_event("x3", 3, "audit.access.chain_verify")},
            {"another tenant's event",
             %{history_event("e4", 4, "audit.access.chain_verify") | "tenant_id" => "tenant-b"}}
          ] do
        result = probes(:history_checks, [capture, capture["events"] ++ [extra], "permitted"])
        assert result["chain_valid"] == "permitted", label
        assert result["captured_events_unchanged"] == "permitted", label

        assert result["appends_accounted"] == "refused:unaccounted_append",
               "#{label}: #{inspect(result)}"

        refute result == @preserved, label
      end
    end

    test "the demo event must be the captured one and commit the row's record hash" do
      event = %{"id" => "e2", "record_sha256" => String.duplicate("a", 64)}
      row = event["record_sha256"]
      assert probes(:demo_event_check, [event, event, row]) == "permitted"

      for {label, captured, current, row_hex, expected} <- [
            {"missing now", event, nil, row, "refused:demo_event_changed"},
            {"another event now", event, %{event | "id" => "e9"}, row,
             "refused:demo_event_changed"},
            {"another committed hash now", event,
             %{event | "record_sha256" => String.duplicate("b", 64)}, row,
             "refused:demo_event_changed"},
            {"never captured", nil, event, row, "refused:demo_event_changed"},
            {"the row's hash moved", event, event, String.duplicate("c", 64),
             "refused:record_hash_mismatch"}
          ] do
        assert probes(:demo_event_check, [captured, current, row_hex]) == expected, label
      end
    end
  end

  ## RED-7 (Codex e95a7340 choices 1, 2, 5; integrated packet refresh)

  @db1_var "SDR_RELEASE_DB1_SUFFIX"
  @db2_var "SDR_RELEASE_DB2_SUFFIX"

  describe "campaign_targets/2 (pure): predeclared, exact, distinct targets" do
    test "two valid distinct suffixes give exactly their two database names" do
      env = %{@db1_var => "_wm0123456789", @db2_var => "_wmabcdef0123", "OTHER" => "x"}

      assert harness(:campaign_targets, [env, "sdr_agent_test_c5"]) ==
               {:ok,
                %{
                  db1: {"_wm0123456789", "sdr_agent_test_wm0123456789"},
                  db2: {"_wmabcdef0123", "sdr_agent_test_wmabcdef0123"}
                }}
    end

    test "an absent, malformed, identical or parent target is refused" do
      valid = %{@db1_var => "_wm0123456789", @db2_var => "_wmabcdef0123"}

      malformed =
        for bad <- [
              "",
              "_wm012345678",
              "_wm01234567890",
              "_WM0123456789",
              "_wmABCDEF0123",
              "_wm0123456789\n",
              " _wm0123456789",
              "_rp0123456789",
              "wm0123456789",
              "_wm0123456789/x"
            ],
            do:
              {"db1 #{inspect(bad)}", %{valid | @db1_var => bad}, "sdr_agent_test_c5",
               {:error, {:target_invalid, @db1_var}}}

      for {label, env, parent, expected} <-
            [
              {"db1 absent", Map.delete(valid, @db1_var), "sdr_agent_test_c5",
               {:error, {:target_unset, @db1_var}}},
              {"db2 absent", Map.delete(valid, @db2_var), "sdr_agent_test_c5",
               {:error, {:target_unset, @db2_var}}},
              {"db2 empty", %{valid | @db2_var => ""}, "sdr_agent_test_c5",
               {:error, {:target_invalid, @db2_var}}},
              {"identical", %{valid | @db2_var => "_wm0123456789"}, "sdr_agent_test_c5",
               {:error, :targets_identical}},
              {"db1 is the parent", valid, "sdr_agent_test_wm0123456789",
               {:error, {:target_is_parent, @db1_var}}},
              {"db2 is the parent", valid, "sdr_agent_test_wmabcdef0123",
               {:error, {:target_is_parent, @db2_var}}}
            ] ++ malformed do
        assert harness(:campaign_targets, [env, parent]) == expected, label
      end
    end

    test "the campaign tests take only the predeclared targets: no random fallback" do
      {:defmodule, _, [_name, [do: {:__block__, _, statements}]]} =
        @external |> File.read!() |> Code.string_to_quoted!()

      db_tests =
        for {:test, _, [name | _]} = node <- statements,
            is_binary(name) and String.starts_with?(name, "DB #"),
            do: node

      assert length(db_tests) == 2, "the DB #1 and DB #2 campaign tests"

      for test <- db_tests do
        refute ast_calls?(test, :suffix), "#{elem(test, 2) |> hd()}: no random suffix"
        assert ast_calls?(test, :targets!), "#{elem(test, 2) |> hd()}: predeclared targets"
      end

      assert ast_calls?(statements, :campaign_targets),
             "targets come from Harness.campaign_targets/2"
    end
  end

  ## The :evidence_dir option: exported inside the harness, before success cleanup

  defp evidence_path, do: Path.join(physical_tmp_root(), "evidence")

  # A probe at "predecessor" that also writes the fixtures, as a real one does.
  defp with_fixtures(root, sfx, answer \\ fn _call -> :default end) do
    fn
      {_, :probe, "predecessor", _} ->
        fn ->
          File.write!(Path.join(owned_tmp(root, sfx), "fixtures.json"), ~s({"captured":"yes"}))
          {:ok, "probe child output"}
        end

      call ->
        answer.(call)
    end
  end

  defp sums!(evidence) do
    for line <-
          evidence |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true),
        into: %{} do
      [hash, path] = String.split(line, "  ", parts: 2)
      {path, hash}
    end
  end

  defp file_sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o777)

  @lineage_children ~w(01-claim 02-migrate-up-20261016052435 03-probe-predecessor
                       04-migrate-up-20261021101539 05-probe-up 06-migrate-down-20261021101539
                       07-probe-down 08-migrate-up-20261021101539 09-probe-up_again 10-drop)

  describe "the :evidence_dir option" do
    test "a completed run exports captures, results and every child, sealed before removal" do
      sfx = suffix()
      root = tmp_root()
      evidence = evidence_path()
      stub = stub(recorder(), :primary, "sdr_agent_test" <> sfx, with_fixtures(root, sfx))

      {outcome, receipts} =
        prove_with_receipts(opts(sfx, stub, root, @lineage, evidence_dir: evidence))

      assert match?({:ok, _}, outcome), inspect(outcome)
      refute File.exists?(owned_tmp(root, sfx)), "the source folder is removed after the seal"
      assert File.dir?(evidence), "the evidence is never cleaned up"
      assert mode(evidence) == 0o700

      sums = sums!(evidence)

      expected =
        ~w(files/fixtures.json files/predecessor.json files/up.json files/down.json
           files/up_again.json) ++
          for(child <- @lineage_children, ext <- ~w(status out), do: "children/#{child}.#{ext}")

      assert Enum.sort(Map.keys(sums)) == Enum.sort(expected)

      for {path, hash} <- sums do
        assert file_sha256(Path.join(evidence, path)) == hash, path
        assert mode(Path.join(evidence, path)) == 0o600, path
      end

      assert File.read!(Path.join(evidence, "files/fixtures.json")) == ~s({"captured":"yes"})

      assert File.read!(Path.join(evidence, "children/03-probe-predecessor.out")) ==
               "probe child output"

      assert File.read!(Path.join(evidence, "children/10-drop.status")) == "exit:0\n"
      assert File.read!(Path.join(evidence, "children/10-drop.out")) == @valid_drop_output

      facts = Map.new(receipts)

      assert Map.take(facts, ~w(evidence.claim evidence.export evidence.files cleanup.temp_folder
                               cleanup.drop_result outcome)) == %{
               "evidence.claim" => "claimed",
               "evidence.export" => "sealed",
               "evidence.files" => Integer.to_string(map_size(sums)),
               "cleanup.temp_folder" => "removed",
               "cleanup.drop_result" => "ok",
               "outcome" => "ok"
             }
    end

    test "child output is bounded, and a runner exception is recorded by its type only" do
      sfx = suffix()
      root = tmp_root()
      evidence = evidence_path()
      big = String.duplicate("a", 40_000) <> "MIDDLE" <> String.duplicate("z", 40_000)

      answer = fn
        {_, :migrate, "up", "20261016052435"} -> {:ok, big}
        {_, :probe, "up", _} -> fn -> raise "SECRET-TEXT from a child" end
        _call -> :default
      end

      stub = stub(recorder(), :primary, "sdr_agent_test" <> sfx, with_fixtures(root, sfx, answer))
      outcome = prove(opts(sfx, stub, root, @lineage, evidence_dir: evidence))

      assert match?({:error, {:cleanup_skipped_unconfirmed_child, _, _}}, outcome),
             inspect(outcome)

      out = File.read!(Path.join(evidence, "children/02-migrate-up-20261016052435.out"))
      assert byte_size(out) <= 65_536 + 64
      assert String.starts_with?(out, "aaaa") and String.ends_with?(out, "zzzz")
      refute out =~ "MIDDLE"
      assert out =~ "bytes elided"

      raised = File.read!(Path.join(evidence, "children/05-probe-up.out"))
      assert File.read!(Path.join(evidence, "children/05-probe-up.status")) == "raised\n"
      assert raised =~ "RuntimeError"
      refute raised =~ "SECRET-TEXT"
    end

    test "an existing destination is a collision: refused before anything, never adopted" do
      sfx = suffix()
      root = tmp_root()
      evidence = evidence_path()
      :ok = File.mkdir(evidence)
      File.write!(Path.join(evidence, "marker"), "kept")
      log = recorder()

      result =
        prove(
          opts(sfx, stub(log, :primary, "sdr_agent_test" <> sfx), root, @lineage,
            evidence_dir: evidence
          )
        )

      assert result == {:error, {:evidence_not_claimed, evidence, :eexist}}
      assert calls(log) == []
      refute File.exists?(owned_tmp(root, sfx))
      assert File.ls!(evidence) == ["marker"]
    end

    test "only a fresh, confined destination outside the folder and the checkout is accepted" do
      sfx = suffix()
      root = tmp_root()
      base = physical_tmp_root()
      real = Path.join(base, "real")
      :ok = File.mkdir(real)
      :ok = File.ln_s(real, Path.join(base, "alias"))
      database = "sdr_agent_test" <> sfx

      assert match?(
               {:ok, _},
               prove(
                 opts(sfx, stub(recorder(), :p, database), root, @lineage,
                   evidence_dir: Path.join(base, "fresh")
                 )
               )
             )

      for {label, bad} <- [
            {"relative", "evidence"},
            {"not normalized", Path.join(base, "real/../evidence")},
            {"a missing parent", Path.join([base, "missing", "evidence"])},
            {"a symlinked ancestor", Path.join([base, "alias", "evidence"])},
            {"inside the harness folder", Path.join(owned_tmp(root, sfx), "evidence")},
            {"the harness folder itself", owned_tmp(root, sfx)},
            {"inside the checkout", Path.join(@root, "tmp-evidence")},
            {"not a path", :evidence}
          ] do
        log = recorder()
        result = prove(opts(sfx, stub(log, :p, database), root, @lineage, evidence_dir: bad))

        assert result == {:error, {:invalid_option, :evidence_dir}},
               "#{label}: #{inspect(result)}"

        assert calls(log) == [], label
        refute File.exists?(owned_tmp(root, sfx)), label
      end

      assert File.ls!(real) == [], "nothing was written through the alias"
    end

    test "a failed export prevents success and keeps the source folder; the evidence is kept" do
      sfx = suffix()
      root = tmp_root()
      evidence = evidence_path()
      outside = Path.join(physical_tmp_root(), "outside.json")
      File.write!(outside, ~s({"outside":true}))
      log = recorder()

      answer = fn
        {_, :probe, "up_again", _} ->
          fn ->
            :ok = File.ln_s(outside, Path.join(owned_tmp(root, sfx), "escape.json"))
            {:ok, ""}
          end

        _call ->
          :default
      end

      stub = stub(log, :primary, "sdr_agent_test" <> sfx, with_fixtures(root, sfx, answer))

      {outcome, receipts} =
        prove_with_receipts(opts(sfx, stub, root, @lineage, evidence_dir: evidence))

      assert match?({:error, {:cleanup_failed, {:evidence_incomplete, _}, {:ok, _}}}, outcome),
             inspect(outcome)

      facts = Map.new(receipts)
      assert facts["evidence.export"] == "failed"
      assert facts["cleanup.temp_folder"] == "retained"
      assert facts["cleanup.temp_folder_retained_reason"] == "evidence_incomplete"
      assert facts["cleanup.drop_result"] == "ok", "the owned database is still disposed"
      assert List.last(calls(log)) == {:primary, :drop}
      assert File.exists?(Path.join(owned_tmp(root, sfx), "fixtures.json")), "source kept"
      assert File.dir?(evidence), "evidence kept"
      refute File.exists?(Path.join(evidence, "SHA256SUMS")), "an incomplete export is not sealed"
      refute File.exists?(Path.join(evidence, "files/escape.json"))
      assert File.read!(outside) == ~s({"outside":true})
    end

    test "an unconfirmed child retains everything, and its evidence is still exported" do
      sfx = suffix()
      root = tmp_root()
      evidence = evidence_path()
      log = recorder()

      answer = fn
        {_, :probe, "up", _} -> {:timeout, :unconfirmed, "partial"}
        _call -> :default
      end

      stub = stub(log, :primary, "sdr_agent_test" <> sfx, with_fixtures(root, sfx, answer))

      {outcome, receipts} =
        prove_with_receipts(opts(sfx, stub, root, @lineage, evidence_dir: evidence))

      assert match?({:error, {:cleanup_skipped_unconfirmed_child, _, _}}, outcome),
             inspect(outcome)

      refute Enum.any?(calls(log), &match?({_, :drop}, &1))
      assert File.dir?(owned_tmp(root, sfx)), "the folder is retained"
      assert Map.new(receipts)["evidence.export"] == "sealed"
      sums = sums!(evidence)
      assert Map.has_key?(sums, "children/05-probe-up.status")
      assert Map.has_key?(sums, "files/fixtures.json")

      assert File.read!(Path.join(evidence, "children/05-probe-up.status")) ==
               "timeout:unconfirmed\n"
    end
  end

  ## The campaign driver's exit taxonomy (pure; Codex e95a7340 point 5)

  defp classify(facts) do
    module = SdrAgent.ReleaseMigration.CampaignExit

    if Code.ensure_loaded?(module) and function_exported?(module, :classify, 1),
      do: Function.capture(module, :classify, 1).(facts),
      else: {:not_implemented, module}
  end

  defp target(database, owned, disposition),
    do: %{database: database, owned: owned, disposition: disposition}

  defp campaign_facts(effects, test, evidence, targets),
    do: %{effects: effects, test: test, evidence: evidence, targets: targets}

  @campaign_targets ~w(sdr_agent_test_rm0 sdr_agent_test_rm0_demo sdr_agent_test_wm0123456789
                       sdr_agent_test_wmabcdef0123)
  @not_created for(
                 db <- @campaign_targets,
                 do: %{database: db, owned: false, disposition: :not_created}
               )
  @disposed for(db <- @campaign_targets, do: %{database: db, owned: true, disposition: :dropped})

  describe "the campaign exit taxonomy (pure)" do
    test "rc 0 only for a pass with every exact target disposed and complete evidence" do
      result = classify(campaign_facts(true, :pass, :complete, @disposed))
      assert match?(%{rc: 0, leases: :release}, result), inspect(result)

      for {label, facts} <- [
            {"a failed test", campaign_facts(true, :fail, :complete, @disposed)},
            {"incomplete evidence", campaign_facts(true, :pass, :incomplete, @disposed)},
            {"inconsistent evidence", campaign_facts(true, :pass, :inconsistent, @disposed)},
            {"a retained target",
             campaign_facts(
               true,
               :pass,
               :complete,
               List.replace_at(
                 @disposed,
                 2,
                 target("sdr_agent_test_wm0123456789", true, :retained)
               )
             )}
          ] do
        refute match?(%{rc: 0}, classify(facts)), label
      end
    end

    test "rc 3 only when no database or application effect occurred" do
      assert match?(
               %{rc: 3, leases: :release},
               classify(campaign_facts(false, :not_run, :incomplete, @not_created))
             )

      foreign = List.replace_at(@not_created, 0, target("sdr_agent_test_rm0", false, :foreign))

      assert match?(%{rc: 3}, classify(campaign_facts(false, :not_run, :incomplete, foreign))),
             "a collision before any effect"

      # A collision after an earlier target was created is never "no effect".
      later =
        @disposed
        |> List.replace_at(2, target("sdr_agent_test_wm0123456789", false, :foreign))
        |> List.replace_at(3, target("sdr_agent_test_wmabcdef0123", false, :not_created))

      result = classify(campaign_facts(true, :not_run, :complete, later))
      assert match?(%{rc: 1, leases: :release}, result), inspect(result)
      assert result.targets == later, "per-target owned/disposition records are kept"
    end

    test "a partial create or setup failure keeps its records: cleaned is rc 1, retained is rc 4" do
      partial = List.replace_at(@not_created, 0, target("sdr_agent_test_rm0", true, :dropped))

      assert match?(
               %{rc: 1, leases: :release},
               classify(campaign_facts(true, :not_run, :complete, partial))
             )

      retained = List.replace_at(@not_created, 0, target("sdr_agent_test_rm0", true, :retained))
      result = classify(campaign_facts(true, :not_run, :complete, retained))
      assert match?(%{rc: 4, leases: :quarantine}, result), inspect(result)
      assert result.targets == retained
    end

    test "uncertainty is rc 5 and keeps every lease, whatever the evidence says" do
      for {label, facts} <- [
            {"an incomplete child", campaign_facts(true, :incomplete, :inconsistent, @disposed)},
            {"an uncertain disposal",
             campaign_facts(
               true,
               :pass,
               :inconsistent,
               List.replace_at(
                 @disposed,
                 3,
                 target("sdr_agent_test_wmabcdef0123", true, :uncertain)
               )
             )},
            {"unknown ownership",
             campaign_facts(
               true,
               :fail,
               :complete,
               List.replace_at(
                 @disposed,
                 1,
                 target("sdr_agent_test_rm0_demo", :unknown, :uncertain)
               )
             )},
            {"uncertain beside retained",
             campaign_facts(true, :fail, :complete, [
               target("a", true, :retained),
               target("b", true, :uncertain)
             ])}
          ] do
        result = classify(facts)
        assert match?(%{rc: 5, leases: :keep}, result), "#{label}: #{inspect(result)}"
      end
    end

    test "evidence trouble never overrides a retained target, and keeps the primary outcome" do
      retained =
        List.replace_at(@disposed, 2, target("sdr_agent_test_wm0123456789", true, :retained))

      result = classify(campaign_facts(true, :fail, :inconsistent, retained))
      assert match?(%{rc: 4, leases: :quarantine, test: :fail, evidence: :inconsistent}, result)

      result = classify(campaign_facts(true, :fail, :incomplete, @disposed))
      assert match?(%{rc: 6, leases: :release, test: :fail, evidence: :incomplete}, result)
    end

    test "facts that cannot be true are refused" do
      for {label, bad} <- [
            {"an unowned target dropped",
             campaign_facts(true, :pass, :complete, [target("a", false, :dropped)])},
            {"an owned target never created",
             campaign_facts(true, :pass, :complete, [target("a", true, :not_created)])},
            {"unknown ownership with a known disposition",
             campaign_facts(true, :pass, :complete, [target("a", :unknown, :dropped)])},
            {"no targets", campaign_facts(true, :pass, :complete, [])},
            {"an unknown test result", campaign_facts(true, :ok, :complete, @disposed)},
            {"an unknown evidence state", campaign_facts(true, :pass, :sealed, @disposed)},
            {"effects not a boolean", campaign_facts(:yes, :pass, :complete, @disposed)},
            {"an extra key",
             Map.put(campaign_facts(true, :pass, :complete, @disposed), :force, true)}
          ] do
        raised =
          try do
            classify(bad)
          rescue
            error in ArgumentError -> error
          end

        assert match?(%ArgumentError{}, raised), "#{label}: #{inspect(raised)}"
      end
    end
  end

  ## Helpers

  # Whether `ast` contains a call to a function named `name` (local or remote).
  defp ast_calls?(ast, name) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _, args} = node, _acc when is_list(args) -> {node, true}
        {{:., _, [_module, ^name]}, _, _args} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # The names of a script's top-level calls, in order (as
  # `SdrAgent.Agents.WitnessMigrationHarnessTest`).
  defp top_level_calls(script) do
    {:__block__, _, statements} =
      @rm |> Path.join(script) |> File.read!() |> Code.string_to_quoted!()

    Enum.flat_map(statements, &calls_in/1)
  end

  defp calls_in({:=, _, [_pattern, expression]}), do: calls_in(expression)
  defp calls_in({:case, _, [expression | _]}), do: calls_in(expression)
  defp calls_in({:|>, _, [left, _right]}), do: calls_in(left)
  defp calls_in({{:., _, [_module, name]}, _, _args}) when is_atom(name), do: [name]
  defp calls_in({:alias, _, _}), do: []

  defp calls_in({name, _, args}) when is_atom(name) and is_list(args) do
    if name in [:__block__, :%{}, :{}], do: [], else: [name]
  end

  defp calls_in(_other), do: []
end

defmodule SdrAgent.Agents.ReleaseMigrationHarnessTest do
  @moduledoc """
  C2* slice S3 RED-6 (S3 plan r2 section 9; Codex 7a9c7eea sequencing items
  2-4): the parameterization of `SdrAgent.WitnessMigration.Harness` that the
  T-S4 release-migration campaign (`SdrAgent.Agents.ReleaseMigrationTest`,
  `:external`) needs, with stubbed children only. No test here opens a
  database connection or starts an OS process: every lifecycle call goes
  through a recording stub, every runner built from the real
  `checked_runner` has an unusable executable, and `no_ports!/1` traces
  every port opened by this process or any process it spawns (a child, a
  socket, a database connection) and fails on one. This module checks out no
  Repo connection, so any Repo use fails loudly. It is `async: false` because
  the port trace is global.

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
    * a per-root build: `checked_runner/5` with `toolchain: :inherit`
      (today's `checked_runner/4`) or `toolchain: :root` (the child uses the
      root's own four Mix roots, re-rooted by the pure `root_toolchain/3`;
      `ERL_LIBS` and every other name are inherited unchanged), refusing a
      missing or symlinked root, an unset or outside Mix root and a missing
      or symlinked re-rooted Mix root as `{:not_started, reason}` before the
      executable check and before any spawn.

  RED classification: the `versions/2`, `root_toolchain/3` and
  `checked_runner/5` tests go through `harness/2`, which reports an absent
  function as `{:not_implemented, name, arity}` (structural); the release
  script effect test is structural (scaffolds). The `prove` option tests
  fail on their semantic assertions (today the options are ignored). Tests
  named `control:` pass now and must keep passing.
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

  ## Fixtures

  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-rm-harness" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
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

        assert result == {:error, {:down_refusal, reason, outcome}},
               "#{label}: #{inspect(result)}"

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

  ## Per-root build (structural until GREEN-6): root_toolchain/3 and checked_runner/5

  describe "root_toolchain/3 (pure)" do
    @own "/w/own"
    @tag_dir "elixir-1.20.4-otp-29.0.5"

    defp devenv(root) do
      state = root <> "/.devenv/state"

      %{
        "MIX_HOME" => state <> "/mix/" <> @tag_dir,
        "HEX_HOME" => state <> "/hex",
        "MIX_DEPS_PATH" => state <> "/deps/" <> @tag_dir,
        "MIX_BUILD_ROOT" => state <> "/build/" <> @tag_dir
      }
    end

    test "the own root keeps each Mix root; another root re-roots each under itself" do
      env = Map.merge(devenv(@own), %{"ERL_LIBS" => "/nix/store/x-hex/lib/erlang/lib/"})
      own = for name <- @mix_roots, do: {name, devenv(@own)[name]}
      base = for name <- @mix_roots, do: {name, devenv("/w/base")[name]}

      assert harness(:root_toolchain, [@own, @own, env]) == {:ok, own}
      assert harness(:root_toolchain, [@own, "/w/base", env]) == {:ok, base}
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
      tmp = tmp_root()
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
        runner = harness(:checked_runner, [exe, suffix(), root, 1_000, [toolchain: :root]])
        assert is_function(runner, 2), "#{label}: #{inspect(runner)}"
        assert no_ports!(fn -> runner.(:claim, ["run"]) end) == expected, label
      end
    end

    test "a well-formed root, and the own root, pass the root checks and still need the executable" do
      tmp = tmp_root()
      exe = Path.join(tmp, "missing")
      base = build_tree!(Path.join(tmp, "base"))

      for root <- [base, @root] do
        runner = harness(:checked_runner, [exe, suffix(), root, 1_000, [toolchain: :root]])
        assert is_function(runner, 2), "#{root}: #{inspect(runner)}"

        assert no_ports!(fn -> runner.(:claim, ["run"]) end) ==
                 {:not_started, {:executable_unusable, exe}},
               root
      end
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

  ## Helpers

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

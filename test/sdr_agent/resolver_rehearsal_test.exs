defmodule SdrAgent.ResolverRehearsalTest do
  @moduledoc """
  The R0-05 resolver browser rehearsal (`SdrAgent.Test.ResolverRehearsal`,
  `SdrAgent.Test.ResolverRehearsal.Fixture`, `mix sdr.demo.rehearse_resolver`).

    * **Guards** (pure): build, environment, Repo, the bounded target name,
      ports, storage (absent only), the exclusive create, the connected and
      fresh target, an idle VM, password, the fake launcher, the dev refusal
      of the task.
    * **Command order** (`run/2` with stubbed effects, no app, database or
      listener): each refusal happens before the effects it guards; once a
      fixture exists its stop always runs, and the command fails unless the
      stop, the counters and the launch count are all confirmed.
    * **Terminal input** (synthetic `StringIO` devices): `STOP`, end of input
      and an unreadable password.
    * **Child environment**: the report's `git` children get no secret
      (a harmless fake `git` on `PATH`, a synthetic canary).
    * **Owned lifecycle** (real fixture in the shared SQL sandbox, plus
      owned stub processes): build, report and clean stop; a failure after
      the tree started; a replacement server and reaper after a resolution
      and a further switch; a tree that does not stop; a process that does
      not exit; an unavailable recorder; an already-running tree.

  The command itself (its database, app start and HTTP listener) is never run.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureIO

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.ResolverRehearsal, as: R
  alias SdrAgent.Test.ResolverRehearsal.Fixture, as: F

  @moduletag timeout: 180_000
  @password "rehearsal-test-password-0001"
  @baseline %{"model_invocations" => 0}

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        mix_env: :test,
        test_seams?: true,
        model_provider: Fake,
        repo: [
          hostname: "localhost",
          port: 5520,
          database: "sdr_agent_test_r1",
          pool: Ecto.Adapters.SQL.Sandbox
        ],
        env: %{"DATABASE_URL" => nil, "SDR_MODEL_PROVIDER" => nil, "SDR_CLAUDE_CLI_BIN" => nil},
        argv: []
      },
      overrides
    )
  end

  defp repo(overrides), do: Keyword.merge(config().repo, overrides)
  defp env(overrides), do: Map.merge(config().env, overrides)

  defp refused(overrides, fragment) do
    assert {:error, reason} = R.plan(config(overrides))
    assert reason =~ fragment
  end

  describe "the plan" do
    test "derives the _rehearsal database, the loopback port and the synthetic admin" do
      assert {:ok, plan} = R.plan(config())
      assert plan.database == "sdr_agent_test_r1_rehearsal"
      assert plan.repo[:database] == "sdr_agent_test_r1_rehearsal"
      assert plan.repo[:pool] == DBConnection.ConnectionPool
      assert {plan.ip, plan.port} == {{127, 0, 0, 1}, 4123}
      assert plan.email == "rehearsal-admin@example.test"
      refute Map.has_key?(plan, :existing_database)

      assert {:ok, %{port: 4199, email: "owner@rehearsal.test"}} =
               R.plan(config(%{argv: ~w(--port 4199 --email owner@rehearsal.test)}))
    end

    test "has no reuse path: --existing-database is an unknown argument" do
      refused(%{argv: ~w(--existing-database sdr_agent_test_r1_rehearsal)}, "unknown arguments")
    end

    test "bounds the target to PostgreSQL's 63-byte identifier limit" do
      # sdr_agent_test (14) + partition + _rehearsal (10).
      ok = "sdr_agent_test" <> String.duplicate("x", 39)
      assert {:ok, %{database: database}} = R.plan(config(%{repo: repo(database: ok)}))
      assert byte_size(database) == 63

      refused(%{repo: repo(database: ok <> "x")}, "64-byte database name")
      # Codex's probe: a 94-byte target.
      refused(%{repo: repo(database: "sdr_agent_test" <> String.duplicate("x", 70))}, "94-byte")
    end

    test "allows only lowercase letters, digits and _ in the target" do
      for partition <- ["_R1", "_r-1", "_r 1", "_r\"1", "_r1é"] do
        refused(%{repo: repo(database: "sdr_agent_test" <> partition)}, "lowercase letters")
      end
    end

    test "refuses any build but the test-seam build" do
      refused(%{mix_env: :dev}, "test-seam build")
      refused(%{test_seams?: false}, "test-seam build")
    end

    test "refuses a DATABASE_URL, a real CLI binary and a non-Fake provider" do
      refused(%{env: env(%{"DATABASE_URL" => "ecto://x/y"})}, "DATABASE_URL")
      refused(%{env: env(%{"SDR_CLAUDE_CLI_BIN" => "/nix/store/x/bin/claude"})}, "real CLI")
      refused(%{env: env(%{"SDR_MODEL_PROVIDER" => "claude_cli"})}, "SDR_MODEL_PROVIDER")
      refused(%{model_provider: ClaudeCLI}, "Fake provider")
    end

    test "refuses the dev, calibration and demo databases and any non-local Repo" do
      refused(%{repo: repo(database: "sdr_agent_dev")}, "sdr_agent_test")
      refused(%{repo: repo(database: "sdr_agent_calibration")}, "sdr_agent_test")
      refused(%{repo: repo(database: "sdr_agent_test_calibration")}, "calibration, demo or dev")
      refused(%{repo: repo(database: "sdr_agent_test_demo")}, "calibration, demo or dev")
      refused(%{repo: repo(database: "sdr_agent_test_dev")}, "calibration, demo or dev")
      refused(%{repo: repo(url: "ecto://postgres@db/sdr_agent_dev")}, ":url")
      refused(%{repo: repo(hostname: "db.example.test")}, "not local")
      refused(%{repo: repo(port: 5432)}, "5520")
    end

    test "refuses the dev, smoke and calibration ports and out-of-range ports" do
      for {port, what} <- [{4120, "dev server"}, {4122, "smoke"}, {4124, "calibration"}] do
        refused(%{argv: ["--port", "#{port}"]}, what)
      end

      refused(%{argv: ~w(--port 80)}, "between 1024")
      refused(%{argv: ~w(--port 70000)}, "between 1024")
    end

    test "refuses unknown arguments and a non-synthetic email" do
      refused(%{argv: ~w(--drop)}, "unknown arguments")
      refused(%{argv: ~w(serve)}, "unknown arguments")
      refused(%{argv: ~w(--email owner@example.com)}, "*.test")
    end
  end

  describe "the storage and the start guards" do
    setup do
      {:ok, plan} = R.plan(config())
      %{plan: plan}
    end

    test "only an absent target is accepted; an existing one is left untouched", ctx do
      assert R.check_storage(ctx.plan, :down) == {:ok, :create}
      assert {:error, exists} = R.check_storage(ctx.plan, :up)
      assert exists =~ "already exists; it is left untouched"
      assert {:error, _} = R.check_storage(ctx.plan, {:error, :econnrefused})
    end

    test "the create is exclusive: a collision is refused, never adopted", ctx do
      assert R.check_created(ctx.plan, :ok) == :ok
      assert {:error, collision} = R.check_created(ctx.plan, {:error, :already_up})
      assert collision =~ "not adopted"
      assert {:error, _} = R.check_created(ctx.plan, {:error, "permission denied"})
    end

    test "migrations need the connected target, fresh", ctx do
      assert R.check_connected(ctx.plan, ctx.plan.database) == :ok
      assert {:error, other} = R.check_connected(ctx.plan, "sdr_agent_test_r1")
      assert other =~ "nothing migrated"
      assert R.check_fresh(true) == :ok
      assert {:error, _} = R.check_fresh(false)
    end

    test "an already-running app, Repo, endpoint or tree is refused" do
      assert R.check_idle([]) == :ok
      assert {:error, reason} = R.check_idle(["SdrAgent.Repo", "the sdr_agent app"])
      assert reason =~ "already running in this VM: SdrAgent.Repo, the sdr_agent app"
      # This test VM runs the app and its Repo: the real probe sees them.
      assert "the sdr_agent app" in R.running()
      assert "SdrAgent.Repo" in R.running()
    end
  end

  test "a port already listening on loopback is refused; a free one is accepted" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    assert {:error, reason} = R.check_port_free(port)
    assert reason =~ "already in use"
    :gen_tcp.close(socket)
    assert R.check_port_free(port) == :ok
  end

  test "the password is typed: empty, short and missing input are refused without echo" do
    assert R.check_password(@password <> "\n") == {:ok, @password}
    assert {:error, empty} = R.check_password("   \n")
    assert {:error, short} = R.check_password("short\n")
    assert {:error, _} = R.check_password(nil)
    refute empty =~ "   "
    refute short =~ "short"
  end

  describe "terminal input (synthetic devices)" do
    test "STOP ends the wait; other lines are ignored" do
      {:ok, device} = StringIO.open("hello\n  STOP  \nlater\n")
      assert R.await_stop(device) == :stop
    end

    test "end of input ends the wait as :eof (never hangs)" do
      for input <- ["", "hello\n", "STOPPED x\n"] do
        {:ok, device} = StringIO.open(input)
        assert R.await_stop(device) == :eof
      end
    end

    test "a password that cannot be read is refused" do
      {:ok, device} = StringIO.open("")
      capture_io(fn -> assert R.check_password(R.read_password(device)) |> elem(0) == :error end)
    end
  end

  describe "the fake-launcher check" do
    setup do
      admission = fn _id, _profile, _opts -> {:error, :rehearsal_no_calls} end

      state = %{
        command: System.find_executable("elixir"),
        command_args: [F.fake_script(), "ready"],
        test_launcher: true,
        executable: nil,
        launch_admission: admission
      }

      %{state: state, admission: admission, attestation: %{test_launcher?: true, executable: nil}}
    end

    test "accepts only the harness's fake CLI under the test launcher", ctx do
      assert F.check_launcher(ctx.state, ctx.attestation, ctx.admission) == :ok
    end

    test "refuses a real CLI command, a pinned executable or a foreign admission", ctx do
      real = %{
        ctx.state
        | command: "/nix/store/abc-llm-proxy-shim/bin/llm-proxy-shim",
          command_args: ["claude"],
          executable: "/nix/store/abc-claude/bin/claude",
          test_launcher: false,
          launch_admission: &Agents.admit_launch/3
      }

      assert {:error, reason} =
               F.check_launcher(real, %{test_launcher?: false, executable: "/x"}, ctx.admission)

      for why <- [
            "not this build's elixir",
            "not the fake CLI script",
            "not under the test launcher",
            "pinned CLI executable",
            "not the driver's recorder",
            "attestation is not a test launcher",
            "attestation names an executable"
          ] do
        assert reason =~ why
      end
    end
  end

  test "the task refuses outside MIX_ENV=test before reading any configuration" do
    on_exit(fn -> Mix.env(:test) end)
    Mix.env(:dev)

    assert_raise Mix.Error, ~r/runs only with MIX_ENV=test/, fn ->
      Mix.Tasks.Sdr.Demo.RehearseResolver.run([])
    end
  end

  @tag :tmp_dir
  test "the report's git children inherit no secret (ChildEnv)", %{tmp_dir: dir} do
    git = Path.join(dir, "git")

    File.write!(git, """
    #!/bin/sh
    if [ -n "$SDR_REHEARSAL_CANARY_SECRET$SDR_REHEARSAL_CANARY" ]; then
      echo canary-visible
    else
      echo canary-absent
    fi
    """)

    File.chmod!(git, 0o755)
    path = System.fetch_env!("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("SDR_REHEARSAL_CANARY_SECRET")
      System.delete_env("SDR_REHEARSAL_CANARY")
    end)

    System.put_env("PATH", dir <> ":" <> path)
    System.put_env("SDR_REHEARSAL_CANARY_SECRET", "synthetic-canary")
    System.put_env("SDR_REHEARSAL_CANARY", "synthetic-canary")

    # Positive control: the fake git is the one found and sees the canary
    # when the environment is inherited.
    assert {"canary-visible\n", 0} = System.cmd("git", ["rev-parse", "HEAD"])
    assert R.code_sha() == {"canary-absent", true}
  end

  ## The command's order (stubbed effects)

  @fixture_session %{before: @baseline, after: @baseline, launches: 0, switch: %{id: "s1"}}
  @clean %{problems: [], launches: 0}

  defp stubs(overrides \\ %{}) do
    me = self()
    {:ok, plan} = R.plan(config())

    call = fn name, result ->
      send(me, {:called, name})
      result
    end

    base = %{
      config: fn _argv -> call.(:config, config()) end,
      running: fn -> call.(:running, []) end,
      port_free: fn _port -> call.(:port_free, :ok) end,
      storage_status: fn _repo -> call.(:storage_status, :down) end,
      assets: fn -> call.(:assets, :ok) end,
      read_password: fn -> call.(:read_password, @password) end,
      apply: fn ^plan -> call.(:apply, :ok) end,
      create: fn ^plan -> call.(:create, :ok) end,
      migrate: fn ^plan -> call.(:migrate, :ok) end,
      start_app: fn -> call.(:start_app, :ok) end,
      verify_started: fn ^plan -> call.(:verify_started, :ok) end,
      create_admin: fn _email, @password -> call.(:create_admin, %{admin: nil}) end,
      start_fixture: fn _ctx -> call.(:start_fixture, @fixture_session) end,
      report: fn _plan, _session -> call.(:report, ["report"]) end,
      await_stop: fn -> call.(:await_stop, :stop) end,
      stop_fixture: fn _session -> call.(:stop_fixture, @clean) end,
      counters: fn -> call.(:counters, @baseline) end,
      info: fn line -> send(me, {:info, line}) end
    }

    Map.merge(base, overrides)
  end

  defp calls(acc \\ []) do
    receive do
      {:called, name} -> calls([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp printed(acc \\ []) do
    receive do
      {:info, line} -> printed([line | acc])
    after
      0 -> Enum.reverse(acc) |> Enum.join("\n")
    end
  end

  @all ~w(config running port_free storage_status assets read_password apply create migrate
          start_app verify_started create_admin start_fixture report await_stop stop_fixture
          counters)a

  describe "the command's order" do
    test "the happy path runs every phase once, in order, and ends clean" do
      assert R.run([], stubs()) == :ok
      assert calls() == @all
      assert printed() =~ "clean stop"
    end

    test "an overlong target is refused before any storage check or effect" do
      long = config(%{repo: repo(database: "sdr_agent_test" <> String.duplicate("x", 70))})

      assert_raise Mix.Error, ~r/94-byte/, fn ->
        R.run([], stubs(%{config: fn _ -> long end}))
      end

      assert calls() == []
    end

    test "an already-running app or Repo is refused before configuration or storage" do
      assert_raise Mix.Error, ~r/already running/, fn ->
        R.run([], stubs(%{running: fn -> ["SdrAgent.Repo"] end}))
      end

      assert calls() == [:config]
    end

    test "an existing target: no create, migrate, app start or fixture write" do
      assert_raise Mix.Error, ~r/already exists; it is left untouched/, fn ->
        R.run([], stubs(%{storage_status: fn _ -> :up end}))
      end

      assert calls() == [:config, :running, :port_free]
    end

    test "a create collision: no migrate, app start or fixture write" do
      assert_raise Mix.Error, ~r/not adopted/, fn ->
        R.run([], stubs(%{create: fn _ -> {:error, :already_up} end}))
      end

      assert calls() ==
               [:config, :running, :port_free, :storage_status, :assets, :read_password, :apply]
    end

    test "a refused migration (wrong or non-fresh target): no app start or fixture write" do
      assert_raise Mix.Error, ~r/nothing migrated/, fn ->
        R.run([], stubs(%{migrate: fn _ -> {:error, "connected to x; nothing migrated"} end}))
      end

      refute :start_app in calls()
    end

    test "a failed start verification: no admin or fixture" do
      assert_raise Mix.Error, ~r/after start/, fn ->
        R.run([], stubs(%{verify_started: fn _ -> {:error, "after start: no"} end}))
      end

      assert List.last(calls()) == :start_app
    end

    test "an unreadable password: no configuration or storage effect" do
      assert_raise Mix.Error, ~r/no password was typed/, fn ->
        R.run([], stubs(%{read_password: fn -> nil end}))
      end

      refute :apply in calls()
    end

    test "changed counters after the build: no report, the stop runs, the command fails" do
      changed = %{@fixture_session | after: %{"model_invocations" => 1}}

      assert_raise Mix.Error, ~r/FAILED.*counters changed after the build/, fn ->
        R.run([], stubs(%{start_fixture: fn _ -> changed end}))
      end

      calls = calls()
      refute :report in calls
      assert :stop_fixture in calls
    end

    test "a launch admitted during the build (or no recorder answer) fails the command" do
      for launches <- [1, nil] do
        session = %{@fixture_session | launches: launches}

        assert_raise Mix.Error, ~r/launch admissions after the build/, fn ->
          R.run([], stubs(%{start_fixture: fn _ -> session end}))
        end

        assert :stop_fixture in calls()
      end
    end

    test "a report failure still stops the fixture and keeps the original error" do
      assert_raise Mix.Error, ~r/the rehearsal failed: synthetic report failure/, fn ->
        R.run([], stubs(%{report: fn _, _ -> raise "synthetic report failure" end}))
      end

      assert :stop_fixture in calls()
    end

    test "an exit or throw while serving still stops the fixture" do
      for await <- [fn -> exit(:synthetic) end, fn -> throw(:synthetic) end] do
        assert_raise Mix.Error, ~r/the rehearsal failed: (exit|throw) :synthetic/, fn ->
          R.run([], stubs(%{await_stop: await}))
        end

        assert :stop_fixture in calls()
      end
    end

    test "end of terminal input stops the fixture like STOP" do
      assert R.run([], stubs(%{await_stop: fn -> :eof end})) == :ok
      assert List.last(calls()) == :counters
      assert printed() =~ "stopped (:eof)"
    end

    test "an unconfirmed cleanup fails the command" do
      unclean = %{problems: ["#PID<0.1.0> did not exit within 10000 ms"], launches: 0}

      assert_raise Mix.Error, ~r/cleanup unconfirmed: #PID<0.1.0> did not exit/, fn ->
        R.run([], stubs(%{stop_fixture: fn _ -> unclean end}))
      end
    end

    test "a stop that itself raises fails the command" do
      assert_raise Mix.Error, ~r/cleanup unconfirmed: the stop itself failed: synthetic/, fn ->
        R.run([], stubs(%{stop_fixture: fn _ -> raise "synthetic" end}))
      end
    end

    test "both the original error and the cleanup problem are named" do
      unclean = %{problems: ["the profile tree did not stop: :timeout"], launches: 0}

      assert_raise Mix.Error, ~r/synthetic report failure.*the profile tree did not stop/, fn ->
        R.run(
          [],
          stubs(%{
            report: fn _, _ -> raise "synthetic report failure" end,
            stop_fixture: fn _ -> unclean end
          })
        )
      end
    end

    test "changed or unreadable final counters, or a late launch, fail the command" do
      assert_raise Mix.Error, ~r/counters changed at stop/, fn ->
        R.run([], stubs(%{counters: fn -> %{"model_invocations" => 2} end}))
      end

      assert_raise Mix.Error, ~r/final counters are unreadable/, fn ->
        R.run([], stubs(%{counters: fn -> raise "connection closed" end}))
      end

      assert_raise Mix.Error, ~r/launch admissions at stop: 1/, fn ->
        R.run([], stubs(%{stop_fixture: fn _ -> %{problems: [], launches: 1} end}))
      end
    end
  end

  ## The owned lifecycle

  describe "the stop of owned stub processes" do
    defp sleeper, do: spawn(fn -> Process.sleep(:infinity) end)

    defp stub_session(tree \\ nil) do
      session = %{F.session(%{}) | tree: tree}
      on_exit(fn -> for pid <- [session.recorder, session.tracker], do: send(pid, :stop) end)
      session
    end

    test "a tree that does not stop is a problem, never swallowed" do
      tree = sleeper()
      on_exit(fn -> Process.exit(tree, :kill) end)

      outcome = F.stop(stub_session(tree), stop_timeout: 200, join_timeout: 200)

      assert Enum.any?(outcome.problems, &(&1 =~ "the profile tree did not stop"))
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
    end

    test "an owned process that does not exit within the join bound is a problem" do
      lingering = sleeper()
      on_exit(fn -> Process.exit(lingering, :kill) end)
      session = stub_session()
      F.own(session, lingering)

      outcome = F.stop(session, join_timeout: 200)

      assert outcome.problems == ["#{inspect(lingering)} did not exit within 200 ms"]
      assert outcome.launches == 0
    end

    test "an unavailable recorder is a problem" do
      session = stub_session()
      send(session.recorder, :stop)
      RH.await!(fn -> not Process.alive?(session.recorder) end, 2_000)

      assert "the launch recorder is unavailable" in F.stop(session).problems
    end

    test "a clean stop of an empty session has no problem" do
      assert %{problems: [], launches: 0} = F.stop(stub_session())
    end
  end

  describe "the fixture" do
    setup do
      RH.lease_cleanup!()
      previous = Application.fetch_env!(:sdr_agent, :model_provider)
      on_exit(fn -> Application.put_env(:sdr_agent, :model_provider, previous) end)
      tenant = bootstrap!()
      %{tenant: tenant}
    end

    # An independent observer of every server, reaper and lease holder under
    # the ClaudeCLI name (sampled every 10 ms) for the joined assertions.
    defp observe! do
      me = self()
      observer = spawn_link(fn -> observe(me, MapSet.new()) end)

      fn ->
        send(observer, {:seen, self()})

        receive do
          {:seen, pids} -> pids
        after
          5_000 -> flunk("the observer did not answer")
        end
      end
    end

    defp observe(parent, pids) do
      receive do
        {:seen, from} ->
          send(from, {:seen, MapSet.to_list(pids)})
          observe(parent, pids)
      after
        10 ->
          lease =
            case Reaper.lease(ClaudeCLI.server()) do
              {:held, pid} -> [pid]
              _ -> []
            end

          now =
            [Process.whereis(ClaudeCLI.server()), ClaudeCLI.reaper(ClaudeCLI.server())] ++ lease

          observe(parent, MapSet.union(pids, MapSet.new(Enum.filter(now, &is_pid/1))))
      end
    end

    test "the ordinary first admin; a real blocked switch; counters unchanged; clean stop",
         ctx do
      %{admin: admin, tenant: tenant} = F.create_admin!("owner@rehearsal.test", @password)
      assert tenant.id == ctx.tenant.id
      assert admin.role == :admin
      assert {:ok, _signed_in} = Accounts.sign_in("owner@rehearsal.test", @password)
      fixture = %{admin: admin, tenant: tenant}
      before = F.counters()
      seen = observe!()

      session = F.start!(fixture)

      stored = F.switch!(fixture, session.switch.id)
      assert {stored.status, stored.failure_reason =~ "coordinator_restarted"} == {:blocked, true}
      assert {:ok, facts} = Agents.blocked_switch_facts(stored, actor: admin)
      assert facts.lease_kind == :survivor

      assert %{hold: :held, generation: 2} = Coordinator.status()
      assert session.status.boot_id != session.first.boot_id
      assert Process.whereis(ClaudeCLI.server()) == session.server
      assert ClaudeCLI.held?(session.server)
      assert Enum.map(session.starts, &elem(&1, 0)) == [1, 2]

      assert {session.before, session.after, session.launches} == {before, before, 0}
      assert R.check_no_calls(session.before, session.after, session.launches, "x") == :ok
      assert Application.get_env(:sdr_agent, :model_provider) == ClaudeCLI

      lines = R.report(%{database: "db", port: 4123, email: "owner@rehearsal.test"}, session)
      text = Enum.join(lines, "\n")
      assert hd(lines) == R.label()
      assert text =~ session.switch.id
      assert text =~ "unchanged: true; completion launch admissions: 0"
      refute text =~ @password

      observed = seen.()
      assert session.server in observed and session.reaper in observed

      outcome = F.stop(session)

      assert %{problems: [], launches: 0, named_server: nil, lease: nil} = outcome
      for pid <- seen.(), do: refute(Process.alive?(pid), "#{inspect(pid)} was joined")
      assert Process.whereis(ProfileSupervisor) == nil
      assert Coordinator.status() == nil
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
      assert F.counters() == before
      assert F.switch!(fixture, session.switch.id).status == :blocked
    end

    test "a resolution and a further switch: the replacement server and reaper are joined",
         ctx do
      %{admin: admin} = F.create_admin!("owner@rehearsal.test", @password)
      fixture = %{admin: admin, tenant: ctx.tenant}
      before = F.counters()
      seen = observe!()
      session = F.start!(fixture)

      # What the browser does: resolve with the exact text, then switch.
      {:ok, facts} = Agents.blocked_switch_facts(session.switch, actor: admin)
      attestation = RH.attestation(session.switch, facts.latest_start, facts.lease_kind)
      assert {:ok, %{switch: %{status: :failed}}} = RH.resolve(session.switch, attestation, admin)
      RH.await_status!(&(&1.hold == :released), 20_000)

      {:ok, setting} = Agents.get_profile_setting(actor: admin)

      to =
        if setting.desired_profile_id == :claude_cli_opus,
          do: :claude_cli_sonnet,
          else: :claude_cli_opus

      assert {:ok, next} =
               Coordinator.request_switch(
                 %{to_profile_id: to, expected_revision: setting.revision},
                 actor: admin
               )

      RH.await!(fn -> match?(%{status: :completed}, F.switch!(fixture, next.id)) end, 30_000)
      RH.await_status!(&(&1.hold == :released and &1.profile_id == to), 20_000)
      replacement = Process.whereis(ClaudeCLI.server())
      assert is_pid(replacement) and replacement != session.server
      replacement_reaper = ClaudeCLI.reaper(replacement)
      assert is_pid(replacement_reaper) and replacement_reaper != session.reaper

      outcome = F.stop(session)

      assert %{problems: [], launches: 0, named_server: nil, lease: nil} = outcome
      observed = seen.()
      assert replacement in observed and replacement_reaper in observed

      for pid <- [session.server, session.reaper, replacement, replacement_reaper | observed],
          do: refute(Process.alive?(pid), "#{inspect(pid)} was joined")

      assert F.counters() == before
    end

    test "a failure after its tree started stops and joins what it acquired", ctx do
      F.create_admin!("owner@rehearsal.test", @password)
      reviewer = human(:reviewer, ctx.tenant)
      before = F.counters()
      seen = observe!()

      # A reviewer may not request a switch: the build fails after the
      # fake-launcher check, before any fault; the original error is raised.
      assert_raise RuntimeError, ~r/\Arehearsal fixture: the switch request was refused/, fn ->
        F.start!(%{admin: reviewer, tenant: ctx.tenant})
      end

      observed = seen.()
      assert observed != [], "the first server and its reaper were seen"
      for pid <- observed, do: refute(Process.alive?(pid), "#{inspect(pid)} was joined")
      assert Process.whereis(ProfileSupervisor) == nil
      assert Process.whereis(ClaudeCLI.server()) == nil
      assert Reaper.lease(ClaudeCLI.server()) == nil
      assert Coordinator.status() == nil
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
      assert F.counters() == before
    end

    test "fails closed when a profile tree already runs, leaving it untouched", ctx do
      %{admin: admin} = F.create_admin!("owner@rehearsal.test", @password)
      tree = RH.tree!()
      RH.await_status!(&(&1.hold == :released))

      assert_raise RuntimeError, ~r/a profile tree is already running/, fn ->
        F.start!(%{admin: admin, tenant: ctx.tenant})
      end

      assert Process.whereis(ProfileSupervisor) == tree
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
    end
  end
end

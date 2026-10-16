defmodule SdrAgent.ResolverRehearsalTest do
  @moduledoc """
  The R0-05 resolver browser rehearsal driver (`SdrAgent.Test.ResolverRehearsal`,
  `mix sdr.demo.rehearse_resolver`): its guards (build, environment,
  database, ports, existing storage, password, fake launcher) and its
  fixture, built in the shared SQL sandbox exactly as the owner-run command
  builds it (a real stored `:blocked` switch through the coordinator,
  counters unchanged, no completion launch) and stopped cleanly. The
  command itself (its database, app start and HTTP listener) is never run
  here.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.ResolverRehearsal, as: R

  @moduletag timeout: 120_000
  @password "rehearsal-test-password-0001"

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
      assert plan.existing_database == nil

      assert {:ok, %{port: 4199, email: "owner@rehearsal.test", existing_database: "x"}} =
               R.plan(
                 config(%{
                   argv: ~w(--port 4199 --email owner@rehearsal.test --existing-database x)
                 })
               )
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

    test "refuses the dev and calibration databases and any non-local Repo" do
      refused(%{repo: repo(database: "sdr_agent_dev")}, "sdr_agent_test")
      refused(%{repo: repo(database: "sdr_agent_calibration")}, "sdr_agent_test")
      refused(%{repo: repo(database: "sdr_agent_test_calibration")}, "calibration or demo")
      refused(%{repo: repo(database: "sdr_agent_test_demo")}, "calibration or demo")
      refused(%{repo: repo(database: "sdr_agent_test-x")}, "_rehearsal database")
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

  describe "the storage" do
    setup do
      {:ok, plan} = R.plan(config())
      %{plan: plan}
    end

    test "creates only an absent database; an existing one only when named exactly", ctx do
      named = %{ctx.plan | existing_database: ctx.plan.database}
      other = %{ctx.plan | existing_database: "sdr_agent_dev"}

      assert R.check_storage(ctx.plan, :down) == {:ok, :create}
      assert R.check_storage(named, :up) == {:ok, :existing}
      assert {:error, already} = R.check_storage(ctx.plan, :up)
      assert already =~ "already exists; it is never dropped or reset"
      assert {:error, missing} = R.check_storage(named, :down)
      assert missing =~ "does not exist"
      assert {:error, wrong} = R.check_storage(other, :up)
      assert wrong =~ "does not name the target database"
      assert {:error, _} = R.check_storage(ctx.plan, {:error, :econnrefused})
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

  describe "the fake-launcher check" do
    setup do
      admission = fn _id, _profile, _opts -> {:error, :rehearsal_no_calls} end

      state = %{
        command: System.find_executable("elixir"),
        command_args: [R.fake_script(), "ready"],
        test_launcher: true,
        executable: nil,
        launch_admission: admission
      }

      %{state: state, admission: admission, attestation: %{test_launcher?: true, executable: nil}}
    end

    test "accepts only the harness's fake CLI under the test launcher", ctx do
      assert R.check_launcher(ctx.state, ctx.attestation, ctx.admission) == :ok
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
               R.check_launcher(real, %{test_launcher?: false, executable: "/x"}, ctx.admission)

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

  describe "the fixture" do
    setup do
      RH.lease_cleanup!()
      previous = Application.fetch_env!(:sdr_agent, :model_provider)
      on_exit(fn -> Application.put_env(:sdr_agent, :model_provider, previous) end)
      tenant = bootstrap!()
      %{tenant: tenant}
    end

    test "the ordinary first admin; a real blocked switch; counters unchanged; clean stop",
         ctx do
      %{admin: admin, tenant: tenant} = R.create_admin!("owner@rehearsal.test", @password)
      assert tenant.id == ctx.tenant.id
      assert admin.role == :admin
      assert {:ok, _signed_in} = Accounts.sign_in("owner@rehearsal.test", @password)
      fixture = %{admin: admin, tenant: tenant}
      before = R.counters()

      session = R.start!(fixture)

      # The stored outcome, read back through the domain as the admin.
      stored = R.switch!(fixture, session.switch.id)
      assert {stored.status, stored.failure_reason =~ "coordinator_restarted"} == {:blocked, true}
      assert {:ok, facts} = Agents.blocked_switch_facts(stored, actor: admin)
      assert facts.lease_kind == :survivor

      assert %{hold: :held, generation: 2} = Coordinator.status()
      assert session.status.boot_id != session.first.boot_id
      assert Process.whereis(ClaudeCLI.server()) == session.server
      assert ClaudeCLI.held?(session.server)
      assert Enum.map(session.starts, &elem(&1, 0)) == [1, 2]

      # No call: every counter as before, no completion launch admitted.
      assert session.before == before
      assert session.after == before
      assert session.launches == 0
      assert Application.get_env(:sdr_agent, :model_provider) == ClaudeCLI

      lines = R.report(%{database: "db", port: 4123, email: "owner@rehearsal.test"}, session)
      text = Enum.join(lines, "\n")
      assert hd(lines) == R.label()
      assert text =~ session.switch.id
      assert text =~ "unchanged: true; completion launch admissions: 0"
      refute text =~ @password

      stopped = R.stop(session)

      assert %{tree_alive?: false, server_alive?: false, reaper_alive?: false, launches: 0} =
               stopped

      assert stopped.named_server == nil
      assert Process.whereis(ProfileSupervisor) == nil
      assert Coordinator.status() == nil
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
      assert R.counters() == before
      assert R.switch!(fixture, session.switch.id).status == :blocked
    end

    test "a failure after its tree started stops that tree and restores the provider", ctx do
      R.create_admin!("owner@rehearsal.test", @password)
      reviewer = human(:reviewer, ctx.tenant)
      before = R.counters()

      # A reviewer may not request a switch: the build fails after the
      # fake-launcher check, before any fault.
      assert_raise RuntimeError, ~r/rehearsal fixture: the switch request was refused/, fn ->
        R.start!(%{admin: reviewer, tenant: ctx.tenant})
      end

      assert Process.whereis(ProfileSupervisor) == nil
      assert Coordinator.status() == nil
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
      assert R.counters() == before
    end

    test "fails closed when a profile tree already runs, leaving it untouched", ctx do
      %{admin: admin} = R.create_admin!("owner@rehearsal.test", @password)
      tree = RH.tree!()
      RH.await_status!(&(&1.hold == :released))

      assert_raise RuntimeError, ~r/a profile tree is already running/, fn ->
        R.start!(%{admin: admin, tenant: ctx.tenant})
      end

      assert Process.whereis(ProfileSupervisor) == tree
      assert Application.get_env(:sdr_agent, :model_provider) == Fake
    end
  end
end

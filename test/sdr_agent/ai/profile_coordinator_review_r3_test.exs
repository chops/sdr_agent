defmodule SdrAgent.AI.ProfileCoordinatorReviewR3Test do
  @moduledoc """
  C2-02b2α GREEN third review regression (Codex CHANGES REQUESTED at
  `1d04d7a`, answer 08a88e30; probe source SHA-256 `593b4715…`): a real
  finalizer timeout followed by an unavailable reconciliation read; once
  the read recovers, the still-pending switch is blocked (section 2a), not
  polled forever, and the server stays held. Real connections: the module
  runs the SQL sandbox in `:auto` mode for its own duration and truncates
  only a test database. No model call.
  """
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AI.ModelProvider.{ClaudeCLI, Coordinator, ProfileSupervisor}
  alias SdrAgent.{Audit, Repo}
  alias SdrAgent.Test.LaunchAdmission

  @tables ~w(model_server_starts model_server_counters model_profile_switches
             model_profile_settings audit_accesses audit_events audit_chain_heads
             model_call_allocations model_call_grants failures operations model_invocations
             agent_runs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    assert String.starts_with?(Repo.config()[:database], "sdr_agent_test"), "not a test database"
    Sandbox.mode(Repo, :auto)
    truncate!()

    on_exit(fn ->
      truncate!()
      Sandbox.mode(Repo, :manual)
      ClaudeCLI.Reaper.release(ClaudeCLI.server())
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant, admin: SdrAgent.AuditCase.new_human(:admin, tenant)}
  end

  test "unknown reconciliation then a known pending outcome blocks rather than retrying forever",
       ctx do
    {:ok, gate} = Agent.start_link(fn -> :unavailable end)

    server = fn _ ->
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: &LaunchAdmission.admitted/3,
        command_args: [Path.expand("../../support/fake_claude_cli.exs", __DIR__), "ready"]
      ]
    end

    start_supervised!(
      {ProfileSupervisor, server: server, faults: [reconcile: fn -> Agent.get(gate, & &1) end]}
    )

    await!(fn -> Coordinator.status().hold == :released end)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :model_coordinator, :stage],
        fn
          _, _, %{stage: :preflighted}, _ ->
            send(parent, {:preflight_paused, self()})
            receive do: (:continue_preflight -> :ok)

          _, _, _, _ ->
            :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, switch} =
             Coordinator.request_switch(
               %{to_profile_id: :claude_cli_sonnet, expected_revision: 1},
               actor: ctx.admin
             )

    assert_receive {:preflight_paused, worker}, 5_000

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows

          Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(ctx.tenant.id)
          ])

          send(parent, {:setting_locked, backend})
          receive do: (:release_setting -> :ok)
        end)
      end)

    try do
      assert_receive {:setting_locked, backend}, 5_000
      send(worker, :continue_preflight)

      await!(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [backend]
        ).rows == [[1]]
      end)

      Process.sleep(2_600)
      _ = :sys.get_state(Coordinator)
      assert status(switch) == "pending", "the real finalizer must have timed out, not committed"
      assert Coordinator.status().hold == :held
      send(holder.pid, :release_setting)
      Task.await(holder, 5_000)
      Agent.update(gate, fn _ -> :read end)
      Process.sleep(800)
      _ = :sys.get_state(Coordinator)

      assert status(switch) == "blocked",
             "read recovered, but known pending outcome is never blocked; coordinator #{inspect(Coordinator.status())}"
    after
      if Process.alive?(holder.pid), do: send(holder.pid, :release_setting)
    end
  end

  defp status(switch) do
    [[status]] =
      Repo.query!("SELECT status FROM model_profile_switches WHERE id = $1", [
        Ecto.UUID.dump!(switch.id)
      ]).rows

    status
  end

  defp await!(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("probe fixture never reached expected state")

      true ->
        Process.sleep(10)
        await!(fun, deadline)
    end
  end

  defp truncate! do
    assert String.starts_with?(Repo.config()[:database], "sdr_agent_test"), "not a test database"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")
    end)
  end
end

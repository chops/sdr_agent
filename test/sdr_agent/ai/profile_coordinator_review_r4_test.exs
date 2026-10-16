defmodule SdrAgent.AI.ProfileCoordinatorReviewR4Test do
  @moduledoc """
  C2-02b2α GREEN fourth review regression (Codex CHANGES REQUESTED at
  `e8a67a6`, answer a08be847; probe source SHA-256 `f5f4bf5c…`): a block
  that itself times out on a held lock is retried from a fresh,
  target-bound read once the database is available, so S ends blocked and
  the server stays held. Real connections (SQL sandbox `:auto` for this
  module only; truncates only a test database). No model call.
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

  test "a timed-out block is reconciled again when the database becomes available", ctx do
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
      Agent.update(gate, fn _ -> :read end)
      # Read recovery permits the pending branch, but the SAME real setting
      # lock makes the block itself spend its separate 2 s call budget.
      Process.sleep(2_600)
      _ = :sys.get_state(Coordinator)

      assert status(switch) == "pending",
             "block should have timed out on the still-held setting lock"

      send(holder.pid, :release_setting)
      Task.await(holder, 5_000)
      Process.sleep(800)
      _ = :sys.get_state(Coordinator)

      assert status(switch) == "blocked",
             "the block timed out, and no further reconciliation or same-action retry occurred after lock release: #{inspect(Coordinator.status())}"
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

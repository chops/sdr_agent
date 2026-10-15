defmodule SdrAgent.AI.ProfileCoordinatorReviewR2Test do
  @moduledoc """
  C2-02b2α GREEN second review regressions (Codex CHANGES REQUESTED at
  `5e10978`, answer d5fff253; probe source SHA-256 `3a4b6d0f…`):

    * R1: a failed boot preflight is never laundered into a same-boot
      adoption; the server stays held.
    * R2: a survivor is re-held before the first database read, and a named
      server outside the supervisor is held, not treated as absent.
    * R3: the cleanup deadline is pinned at the acknowledged subscription,
      and a receipt consumed after it is not a confirmation.
    * R4: a failed reconciliation observation is retried.

  The fake CLI under the test launcher; no model call.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.{ClaudeCLI, Coordinator, ProfileSupervisor}
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.Test.LaunchAdmission

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    tenant = bootstrap!()

    on_exit(fn ->
      case Reaper.lease(ClaudeCLI.server()) do
        {:held, holder} ->
          ref = Process.monitor(holder)

          receive do
            {:DOWN, ^ref, :process, ^holder, _} -> :ok
          after
            10_000 -> flunk("test reaper did not exit")
          end

        nil ->
          :ok
      end

      Reaper.release(ClaudeCLI.server())
    end)

    %{tenant: tenant, admin: human(:admin, tenant), runtime: system_actor(:agent_runtime, tenant)}
  end

  test "a failed boot preflight must not become a released same-boot adoption", ctx do
    tree!(server: fn _ -> Keyword.put(options(), :command, nil) end)
    await!(fn -> Coordinator.status().generation == 1 end)
    _ = :sys.get_state(Coordinator)
    assert Coordinator.status().hold == :held

    assert {:error, :shim_not_found} =
             Coordinator.preflight(Process.whereis(ClaudeCLI.server()), :claude_cli_opus)

    Process.sleep(1_300)
    _ = :sys.get_state(Coordinator)
    {:ok, starts} = Agents.list_server_starts(actor: ctx.runtime)

    assert Coordinator.status().hold == :held,
           "failed preflight was bypassed on retry: #{inspect(Coordinator.status())}; starts #{inspect(Enum.map(starts, &Map.take(&1, [:status, :ready_evidence, :boot_id])))}"

    assert ClaudeCLI.held?(ClaudeCLI.server())
  end

  test "a restart must rehold its survivor before the singleton DB read returns" do
    tree!()
    await!(fn -> Coordinator.status().hold == :released end)
    old = Process.whereis(Coordinator)
    old_server = Process.whereis(ClaudeCLI.server())
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _, _, meta, _ ->
          if self() == Process.whereis(Coordinator) and self() != old and
               String.contains?(meta.query, "FROM \"tenants\"") do
            send(parent, {:singleton_paused, self()})
            receive do: (:continue_singleton -> :ok)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    monitor = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old, :killed}, 5_000
    assert_receive {:singleton_paused, restarted}, 5_000
    held = ClaudeCLI.held?(old_server)
    send(restarted, :continue_singleton)
    _ = :sys.get_state(Coordinator)
    assert held, "survivor remained callable while new coordinator waited in its first DB read"
  end

  test "an unmanaged named server must not remain unheld during boot retry" do
    tree!(manual: true)

    unmanaged =
      start_supervised!(
        {ClaudeCLI, Keyword.merge(options(), name: ClaudeCLI.server(), profile: :claude_cli_opus)}
      )

    refute ClaudeCLI.held?(unmanaged)
    send(Process.whereis(Coordinator), :boot)
    _ = :sys.get_state(Coordinator)

    assert ClaudeCLI.held?(unmanaged),
           "unmanaged named server was treated as absent and left callable"
  end

  test "time spent after subscription acknowledgment cannot reset the cleanup deadline", ctx do
    tree!(cleanup_wait_ms: 200)
    await!(fn -> Coordinator.status().hold == :released end)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :model_coordinator, :stage],
        fn
          _, _, %{stage: :old_stopping}, _ ->
            send(parent, {:after_subscription, self()})
            receive do: (:continue_stop -> :ok)

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

    assert_receive {:after_subscription, coordinator}, 5_000
    Process.sleep(450)
    send(coordinator, :continue_stop)

    await!(fn ->
      {:ok, rows} = Agents.list_profile_switches(actor: ctx.admin)
      Enum.find(rows, &(&1.id == switch.id)).status != :pending
    end)

    {:ok, rows} = Agents.list_profile_switches(actor: ctx.admin)
    result = Enum.find(rows, &(&1.id == switch.id))

    assert result.status == :blocked,
           "expired cleanup stage proceeded to #{inspect(result.status)} after resetting deadline"
  end

  test "a receipt queued while coordinator is suspended must not be accepted past deadline",
       ctx do
    tree!(cleanup_wait_ms: 200)
    await!(fn -> Coordinator.status().hold == :released end)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :model_coordinator, :stage],
        fn
          _, _, %{stage: :old_stopping}, _ ->
            send(parent, {:after_subscription, self()})
            receive do: (:continue_stop -> :ok)

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

    assert_receive {:after_subscription, coordinator}, 5_000
    old = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(old)
    true = :erlang.suspend_process(reaper)

    try do
      send(coordinator, :continue_stop)
      await!(fn -> not Process.alive?(old) end)
      true = :erlang.suspend_process(coordinator)

      try do
        true = :erlang.resume_process(reaper)
        await!(fn -> not Process.alive?(reaper) end)
        Process.sleep(450)
      after
        :erlang.resume_process(coordinator)
      end

      await!(fn ->
        {:ok, rows} = Agents.list_profile_switches(actor: ctx.admin)
        Enum.find(rows, &(&1.id == switch.id)).status != :pending
      end)

      {:ok, rows} = Agents.list_profile_switches(actor: ctx.admin)
      result = Enum.find(rows, &(&1.id == switch.id))

      assert result.status == :blocked,
             "late receipt passed an expired cleanup stage: #{inspect(result.status)}"
    after
      if Process.alive?(reaper), do: :erlang.resume_process(reaper)
    end
  end

  test "a failed reconciliation observation is retried after the observation recovers", ctx do
    tree!()
    await!(fn -> Coordinator.status().hold == :released end)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :model_coordinator, :stage],
        fn
          _, _, %{stage: :finalizing}, _ ->
            send(parent, {:before_finalization, self()})
            receive do: (:continue_finalization -> :ok)

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

    assert_receive {:before_finalization, coordinator}, 5_000
    lease = Reaper.lease(ClaudeCLI.server())
    assert {:held, holder} = lease
    assert Process.alive?(holder)
    :persistent_term.erase({Reaper, ClaudeCLI.server()})

    try do
      send(coordinator, :continue_finalization)
      _ = :sys.get_state(Coordinator)
      {:ok, rows} = Agents.list_profile_switches(actor: ctx.admin)
      assert Enum.find(rows, &(&1.id == switch.id)).status == :completed
      assert Coordinator.status().hold == :held
    after
      :persistent_term.put({Reaper, ClaudeCLI.server()}, lease)
    end

    # The exact live owner and lease are now visible again. No model call.
    Process.sleep(500)
    _ = :sys.get_state(Coordinator)

    assert Coordinator.status().hold == :released,
           "successful finalization remained held with no reconciliation retry after observation recovered"
  end

  defp tree!(extra \\ []),
    do:
      start_supervised!(
        {ProfileSupervisor, Keyword.put_new(extra, :server, fn _ -> options() end)}
      )

  defp options,
    do: [
      command: System.find_executable("elixir"),
      test_launcher: true,
      launch_admission: &LaunchAdmission.admitted/3,
      command_args: [@fake, "ready"]
    ]

  defp await!(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("probe fixture did not settle")

      true ->
        Process.sleep(10)
        await!(fun, deadline)
    end
  end
end

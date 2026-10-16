defmodule SdrAgent.AI.ProfileCoordinatorReviewTest do
  @moduledoc """
  C2-02b2α GREEN review regressions (Codex CHANGES REQUESTED at `bce5653`,
  answer c4db4384; probe source SHA-256 `fba2b8d5…`): the invariants the
  first GREEN missed, kept as permanent tests.

    * MF1: a blocked switch at a coordinator restart keeps the hold.
    * MF2: adoption needs the desired profile and the reaper's own lease.
    * MF3: direct resource actions can't rewrite a started identity, and a
      replay with changed facts is refused.
    * MF4: a named reaper never certifies a lease it didn't release.
    * MF5: the cleanup bound includes the synchronous stop.
    * MF6: a proven candidate start failure takes the rollback path.

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
        {:held, pid} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            10_000 -> flunk("probe reaper remained alive")
          end

        nil ->
          :ok
      end

      Reaper.release(ClaudeCLI.server())
    end)

    %{tenant: tenant, admin: human(:admin, tenant), runtime: system_actor(:model_runtime, tenant)}
  end

  test "restart keeps a historical blocked switch held", ctx do
    tree!()
    before = settled!()

    assert {:ok, switch} =
             Agents.request_profile_switch(
               %{
                 to_profile_id: :claude_cli_sonnet,
                 expected_revision: 1,
                 server_generation: before.generation
               },
               actor: ctx.admin
             )

    assert {:ok, _blocked} =
             Coordinator.test_run(
               fn binding ->
                 {:ok, starts} = Agents.list_server_starts(actor: ctx.runtime)

                 Agents.block_profile_switch(
                   switch,
                   %{
                     boot_id: binding.boot_id,
                     start_id: List.last(starts).id,
                     server_generation: switch.server_generation,
                     failure_reason: "probe historical block"
                   },
                   actor: ctx.runtime
                 )
               end,
               5_000
             )

    assert {:held, _} = ClaudeCLI.hold(ClaudeCLI.server(), make_ref())
    restart!()
    after_boot = settled!(before.boot_id)
    assert after_boot.hold == :held, "a blocked switch reopened: #{inspect(after_boot)}"
    assert ClaudeCLI.held?(ClaudeCLI.server())
  end

  test "a surviving child at the wrong desired profile is never released as adopted", _ctx do
    tree!(manual: true)
    before = Coordinator.status()
    opts = server_opts() |> Keyword.merge(name: ClaudeCLI.server(), profile: :claude_cli_sonnet)
    spec = Supervisor.child_spec({ClaudeCLI, opts}, restart: :temporary)

    assert {:ok, _pid} =
             DynamicSupervisor.start_child(SdrAgent.AI.ModelProvider.ServerSupervisor, spec)

    send(Process.whereis(Coordinator), :boot)
    after_boot = settled!()

    assert after_boot.hold == :held or after_boot.profile_id == :claude_cli_opus,
           "wrong-profile survivor released: #{inspect(after_boot)} (boot #{before.boot_id})"
  end

  test "adoption without the published reaper's lease keeps the hold", _ctx do
    tree!()
    before = settled!()
    :persistent_term.erase({Reaper, ClaudeCLI.server()})
    restart!()
    after_boot = settled!(before.boot_id)
    assert after_boot.hold == :held, "uncertified lease absence reopened: #{inspect(after_boot)}"
  end

  test "direct Ash action in coordinator cannot rewrite recorded started identity", ctx do
    tree!(manual: true)

    assert {:error, _} =
             Coordinator.test_run(
               fn binding ->
                 {:ok, start} =
                   Agents.allocate_server_start(
                     %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
                     actor: ctx.runtime
                   )

                 {:ok, pid} =
                   DynamicSupervisor.start_child(
                     SdrAgent.AI.ModelProvider.ServerSupervisor,
                     Supervisor.child_spec(
                       {ClaudeCLI,
                        server_opts()
                        |> Keyword.merge(
                          name: ClaudeCLI.server(),
                          profile: :claude_cli_opus,
                          hold: make_ref()
                        )},
                       restart: :temporary
                     )
                   )

                 {:ok, start} =
                   Agents.mark_server_start(
                     start,
                     :started,
                     %{
                       boot_id: binding.boot_id,
                       pid: pid,
                       node: node(),
                       reaper_pid: ClaudeCLI.reaper(pid)
                     },
                     actor: ctx.runtime
                   )

                 start
                 |> Ash.Changeset.for_update(
                   :mark_started,
                   %{pid: "FORGED", node: "FORGED", reaper_pid: "FORGED"},
                   actor: ctx.runtime
                 )
                 |> Ash.update()
               end,
               5_000
             )
  end

  test "started replay rejects changed node or reaper facts", ctx do
    tree!(manual: true)

    assert {:error, _} =
             Coordinator.test_run(
               fn binding ->
                 {:ok, start} =
                   Agents.allocate_server_start(
                     %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
                     actor: ctx.runtime
                   )

                 {:ok, pid} =
                   DynamicSupervisor.start_child(
                     SdrAgent.AI.ModelProvider.ServerSupervisor,
                     Supervisor.child_spec(
                       {ClaudeCLI,
                        server_opts()
                        |> Keyword.merge(
                          name: ClaudeCLI.server(),
                          profile: :claude_cli_opus,
                          hold: make_ref()
                        )},
                       restart: :temporary
                     )
                   )

                 {:ok, start} =
                   Agents.mark_server_start(
                     start,
                     :started,
                     %{
                       boot_id: binding.boot_id,
                       pid: pid,
                       node: node(),
                       reaper_pid: ClaudeCLI.reaper(pid)
                     },
                     actor: ctx.runtime
                   )

                 Agents.mark_server_start(
                   start,
                   :started,
                   %{
                     boot_id: binding.boot_id,
                     pid: pid,
                     node: :changed_node,
                     reaper_pid: Process.whereis(ProfileSupervisor)
                   },
                   actor: ctx.runtime
                 )
               end,
               5_000
             )
  end

  test "a named reaper does not certify a lease that was manually erased", _ctx do
    parent = self()
    name = :codex_bce5653_erased_lease

    {owner, owner_ref} =
      spawn_monitor(fn ->
        {:ok, reaper} = Reaper.start(name)
        send(parent, {:probe_reaper, reaper})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:probe_reaper, reaper}, 2_000
    ref = make_ref()
    assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)
    down = Process.monitor(reaper)
    :persistent_term.erase({Reaper, name})
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 2_000
    assert_receive {:DOWN, ^down, :process, ^reaper, _}, 2_000

    refute_received {:reaper_cleanup_confirmed, ^ref, _},
                    "the reaper did not release its own lease but issued a cleanup receipt"
  end

  test "a known candidate start failure takes the rollback path", ctx do
    tree!(
      server: fn profile ->
        if profile == :claude_cli_sonnet,
          do: Keyword.put(server_opts(), :timeout, 1),
          else: server_opts()
      end
    )

    settled!()

    assert {:ok, switch} =
             Coordinator.request_switch(
               %{to_profile_id: :claude_cli_sonnet, expected_revision: 1},
               actor: ctx.admin
             )

    terminal = switch_terminal(ctx, switch.id, System.monotonic_time(:millisecond) + 5_000)

    assert terminal.status == :failed,
           "known pre-start failure did not rollback: #{inspect(terminal.status)}"

    assert Coordinator.status().profile_id == :claude_cli_opus
  end

  test "cleanup's bound includes the synchronous stop", ctx do
    tree!(cleanup_wait_ms: 200)
    settled!()
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :model_coordinator, :stage],
        fn
          _, _, %{stage: :old_stopping}, _ ->
            send(parent, {:probe_stopping, self()})
            receive do: (:probe_continue -> :ok)

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

    assert_receive {:probe_stopping, coordinator}, 5_000
    old = Process.whereis(ClaudeCLI.server())
    # Make the controlled server process require mailbox handling for
    # shutdown, rather than exiting immediately on the exit signal.
    _ =
      :sys.replace_state(old, fn state ->
        Process.flag(:trap_exit, true)
        state
      end)

    true = :erlang.suspend_process(old)

    try do
      send(coordinator, :probe_continue)
      Process.sleep(600)
      {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
      current = Enum.find(switches, &(&1.id == switch.id))

      assert current.status == :blocked,
             "200ms cleanup bound still not acted on after 600ms: #{inspect(current.status)}"
    after
      if Process.alive?(old), do: :erlang.resume_process(old)
      _ = switch_terminal(ctx, switch.id, System.monotonic_time(:millisecond) + 5_000)
      _ = :sys.get_state(Coordinator)
    end
  end

  defp server_opts,
    do: [
      command: System.find_executable("elixir"),
      test_launcher: true,
      launch_admission: &LaunchAdmission.admitted/3,
      command_args: [@fake, "ready"]
    ]

  defp tree!(extra \\ []),
    do:
      start_supervised!(
        {ProfileSupervisor, Keyword.put_new(extra, :server, fn _ -> server_opts() end)}
      )

  defp switch_terminal(ctx, id, deadline) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    current = Enum.find(switches, &(&1.id == id))

    cond do
      current.status != :pending ->
        current

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("probe switch did not settle")

      true ->
        Process.sleep(20)
        switch_terminal(ctx, id, deadline)
    end
  end

  defp restart! do
    old = Process.whereis(Coordinator)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000
  end

  defp settled!(old_boot \\ nil), do: poll(System.monotonic_time(:millisecond) + 10_000, old_boot)

  defp poll(deadline, old_boot) do
    state = Coordinator.status()

    cond do
      is_map(state) and state.boot_id != old_boot and state.hold in [:held, :released] and
          is_integer(state.generation) ->
        # Drain already-enqueued continuation work before inspecting the outcome.
        _ = :sys.get_state(Coordinator)
        Coordinator.status()

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("probe boot did not settle: #{inspect(state)}")

      true ->
        Process.sleep(20)
        poll(deadline, old_boot)
    end
  end
end

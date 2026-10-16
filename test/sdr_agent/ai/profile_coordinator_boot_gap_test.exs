defmodule SdrAgent.AI.ProfileCoordinatorBootGapTest do
  @moduledoc """
  C2-02b2α regression for the boot gap (`docs/product/r0/c2-02b2b-interface.md`,
  "Prerequisite correction: the b2α boot gap"; Codex `098ce609`,
  `codex-c202c-b659d21-red-review.md`, "Boot-gap ruling"). It needs neither
  the b2β resolver nor the C2-02c status fields.

  b2α's accepted rule: a switch still pending at a coordinator start is
  blocked (`coordinator_restarted`). Each case below reaches a coordinator
  start whose first start of its own boot does not end ready, with a switch
  pending:

    * **the held first start:** the restarted boot's first start fails its
      no-call preflight;
    * **the never-started first start:** the restarted boot's first start is
      allocated, then its server never starts;
    * **a dead lease:** the old server and its reaper are killed (both
      suspended first, so no cleanup receipt), then the coordinator.

  In each, the switch is blocked through the registered coordinator's own
  `block` (its stored latest-start fence), the runtime stays held (never
  released), and nothing calls `Reaper.release/1` except the test. A blocked
  switch at a later failed start is left as it is.

  The control: an unmanaged named process that acknowledges the hold before
  this boot has allocated anything produces the same held tuple, and grants
  nothing: the switch stays pending and no start is allocated by that boot.

  Shared SQL sandbox; the fake CLI; no model call.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.ResolveHarness,
    only: [
      await!: 3,
      await_status!: 1,
      kill!: 1,
      kill_coordinator!: 0,
      lease_cleanup!: 0,
      pause_stage!: 1,
      release_callers: 1,
      request_switch!: 1,
      starts!: 1,
      status: 0,
      switch!: 2,
      sync: 0,
      trace_release!: 0
    ]

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.LaunchAdmission

  @moduletag :c2_02b2b
  @moduletag timeout: 120_000

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    tenant = bootstrap!()
    lease_cleanup!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  test "the held first start: a pending switch at a restart whose first start fails its preflight is blocked",
       ctx do
    {mode, switch} = pending_switch_at_restart!(ctx)
    Agent.update(mode, fn _ -> :failing_preflight end)
    old_server!()
    tracer = trace_release!()
    before = status()

    kill_coordinator!()

    blocked = await_blocked!(ctx, switch)
    status = await_status!(&(&1.boot_id != before.boot_id))
    latest = List.last(starts!(ctx))

    assert latest.boot_id == status.boot_id and latest.status == :failed,
           "this boot's own first start is its fence: #{inspect(latest)}"

    assert_held!()
    assert release_callers(tracer) == []

    # A blocked switch at the next failed start is left as it is.
    events = subject_events(ctx, switch.id)
    kill_coordinator!()
    await_status!(&(&1.boot_id != status.boot_id))
    sync()
    assert switch!(ctx, switch.id) == blocked
    assert subject_events(ctx, switch.id) == events
    assert_held!()
  end

  test "the never-started first start: a pending switch at a restart is blocked", ctx do
    {mode, switch} = pending_switch_at_restart!(ctx)
    Agent.update(mode, fn _ -> :never_starts end)
    old_server!()
    tracer = trace_release!()
    before = status()

    kill_coordinator!()

    await_blocked!(ctx, switch)
    status = await_status!(&(&1.boot_id != before.boot_id))

    assert Enum.any?(
             starts!(ctx),
             &(&1.boot_id == status.boot_id and &1.status == :failed and is_nil(&1.pid))
           ),
           "this boot allocated its first start, which never started"

    assert status.hold != :released
    assert Process.whereis(ClaudeCLI.server()) == nil
    assert release_callers(tracer) == []
  end

  test "a dead lease at a restart: the pending switch is blocked, nothing runs or is released",
       ctx do
    {_mode, switch} = pending_switch_at_restart!(ctx)
    tracer = trace_release!()
    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    true = :erlang.suspend_process(server)
    true = :erlang.suspend_process(reaper)
    kill!(server)
    kill!(reaper)
    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}
    before = status()

    kill_coordinator!()

    await_blocked!(ctx, switch)
    status = await_status!(&(&1.boot_id != before.boot_id))

    assert Enum.any?(starts!(ctx), &(&1.boot_id == status.boot_id)),
           "this boot allocated its own first start (its fence)"

    Process.sleep(1_500)
    assert status().hold != :released

    assert Process.whereis(ClaudeCLI.server()) == nil,
           "no failed live child behind the dead lease"

    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}, "the lease is untouched"
    refute Enum.any?(starts!(ctx), &(&1.boot_id == status.boot_id and &1.status == :ready))
    assert release_callers(tracer) == []
  end

  test "control: an unmanaged named process before any allocation grants nothing", ctx do
    {_mode, switch} = pending_switch_at_restart!(ctx)
    old_server!()
    starts = starts!(ctx)
    unmanaged = start_supervised!({__MODULE__.Unmanaged, ClaudeCLI.server()})
    before = status()

    kill_coordinator!()

    status = await_status!(&(&1.boot_id != before.boot_id))
    Process.sleep(1_500)
    sync()

    assert %{status: :pending} = switch!(ctx, switch.id),
           "a held tuple without this boot's own allocation never blocks"

    assert starts!(ctx) == starts, "nothing allocated for the unmanaged process"
    assert status().boot_id == status.boot_id and status().hold != :released
    assert Process.whereis(ClaudeCLI.server()) == unmanaged
  end

  ## Fixtures

  # The tree, whose server options follow `mode` (`:ready`,
  # `:failing_preflight` or `:never_starts`); a switch requested and paused
  # after its drain; the coordinator not yet killed.
  defp pending_switch_at_restart!(ctx) do
    {:ok, mode} = Agent.start_link(fn -> :ready end)
    tree!(mode)
    await_status!(&(&1.hold == :released))
    pause_stage!(:drained)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :drained, _worker}, 20_000
    {mode, switch}
  end

  defp tree!(mode) do
    parent = self()

    server = fn _profile_id ->
      base = [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake, "ready"]
      ]

      case Agent.get(mode, & &1) do
        :ready -> base
        :failing_preflight -> Keyword.put(base, :command, nil)
        :never_starts -> Keyword.put(base, :timeout, 1)
      end
    end

    start_supervised!({ProfileSupervisor, server: server})
  end

  # The old server stops normally: its reaper cleans up and releases the
  # lease, so the restarted boot starts a fresh first start.
  defp old_server! do
    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    kill!(server)
    await!(fn -> not Process.alive?(reaper) end, 10_000, "the old reaper never exited")
    assert Reaper.lease(ClaudeCLI.server()) == nil
  end

  defp await_blocked!(ctx, switch) do
    await!(
      fn -> match?(%{status: :blocked}, switch!(ctx, switch.id)) end,
      15_000,
      fn ->
        "C2-02b2α boot gap: a switch pending at the restart must be blocked; " <>
          "got #{inspect(switch!(ctx, switch.id))}"
      end
    )

    blocked = switch!(ctx, switch.id)
    assert blocked.failure_reason =~ "coordinator_restarted"
    blocked
  end

  defp assert_held! do
    assert status().hold != :released
    server = Process.whereis(ClaudeCLI.server())

    if is_pid(server) do
      assert ClaudeCLI.held?(server)
      assert Runtime.resolve(provider: ClaudeCLI) == {:error, :provider_held}
    end
  end

  defp subject_events(ctx, id),
    do: ctx.tenant |> events() |> Enum.filter(&(&1.subject_id == id)) |> Enum.map(& &1.id)

  defmodule Unmanaged do
    @moduledoc false
    # A process registered under the server's name that is no
    # ServerSupervisor child; it acknowledges a hold like a server.
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call({:hold, ref}, _from, state), do: {:reply, {:held, ref}, state}
    def handle_call(_message, _from, state), do: {:reply, {:error, :unmanaged}, state}
  end
end

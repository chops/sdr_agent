defmodule SdrAgent.AI.ProfileCoordinatorResolveReviewTest do
  @moduledoc """
  C2-02b2β GREEN review regressions (Codex CHANGES REQUESTED at `5e7f066`,
  `codex-c202b2beta-5e7f066-green-review.md`). The first three tests are
  Codex's executable probes (`codex_c202b2b_5e7f066_review_test.exs`, SHA256
  `4933d2c8…`), kept with their assertions unchanged; only the module name,
  the tags and the fake CLI's path (this worktree's) differ:

    * MF1: a resolution never adopts this boot's own failed-preflight server
      into ready evidence, and never releases it;
    * MF2: a queued `:boot` retry starts nothing while a settlement is
      pending (state injection of the exact `unknown/2` shape);
    * MF3: the resolution CHECK rejects a NULL `finished_at`.

  The last test (MF2, resumption) injects the same pending settlement over
  a definitely uncommitted resolution: stale `:boot` and `:replace`
  messages start nothing while it is pending; once the settlement's own
  barrier and re-read prove the outcome definite, the deferred boot retry
  resumes. Elapsed time and absence are never the proof.

  Shared SQL sandbox; the fake CLI; no model call.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.ResolveHarness

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission

  @moduletag :c2_02b2b
  @moduletag timeout: 120_000

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    tenant = bootstrap!()
    lease_cleanup!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  test "resolution cannot adopt this boot's own failed-preflight server into ready", ctx do
    {:ok, mode} = Agent.start_link(fn -> :ready end)
    parent = self()

    server_fun = fn _profile ->
      command = if Agent.get(mode, & &1) == :ready, do: System.find_executable("elixir")

      [
        command: command,
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake, "ready"]
      ]
    end

    start_supervised!({ProfileSupervisor, server: server_fun})
    await_status!(&(&1.hold == :released))
    pause = pause_stage!(:drained)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :drained, _worker}, 20_000
    :telemetry.detach(pause)
    Agent.update(mode, fn _ -> :failing_preflight end)

    old = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(old)
    kill!(old)
    await!(fn -> not Process.alive?(reaper) end)
    assert Reaper.lease(ClaudeCLI.server()) == nil
    kill_coordinator!()
    blocked = await_switch!(ctx, switch.id, :blocked)
    sync()
    latest = latest_start!(ctx)
    pid = Process.whereis(ClaudeCLI.server())
    assert latest.status == :failed
    assert Coordinator.preflight(pid, latest.profile_id) != :ok
    assert :sys.get_state(Coordinator).spawned == pid
    assert status().hold == :held

    result = resolve(blocked, attestation(blocked, latest, :survivor), ctx.admin)
    assert match?({:ok, %{switch: _}}, result)
    sync()

    refute status().hold == :released,
           "failed no-call preflight was laundered into ready/released by adoption: #{inspect(status())}"

    refute Enum.any?(starts!(ctx), &(&1.pid == inspect(pid) and &1.status == :ready)),
           "the failed-preflight pid became a ready adopted replacement without passing preflight"
  end

  test "a queued boot retry cannot allocate or start while settlement is pending (state injection)",
       ctx do
    blocked = none!(ctx)
    latest = latest_start!(ctx)
    before = starts!(ctx)

    settlement = %{
      switch_id: blocked.id,
      attestation: attestation(blocked, latest, :none),
      resolver_id: ctx.admin.id
    }

    # Isolate the protocol gate using the exact state shape of unknown/2.
    # This is not presented as an end-to-end unknown-COMMIT reproduction.
    :sys.replace_state(Coordinator, &%{&1 | settling: settlement})
    send(Coordinator, :boot)
    sync()

    assert :sys.get_state(Coordinator).settling == settlement

    assert starts!(ctx) == before,
           "boot retry allocated/started before the pending settlement was proven"

    assert Process.whereis(ClaudeCLI.server()) == nil
  end

  test "resolution check rejects a null finished_at when resolved_at is set", ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)

    assert match?(
             {:ok, _},
             resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)
           )

    sync()

    # Deliberate DB-constraint negative probe in this test's sandbox row.
    # No trigger bypass, no production or owner database.
    result =
      Repo.transaction(fn ->
        case Repo.query(
               "UPDATE model_profile_switches SET finished_at = NULL WHERE id = $1",
               [Ecto.UUID.dump!(blocked.id)]
             ) do
          {:ok, _} -> :accepted_null_finished_at
          {:error, error} -> Repo.rollback(error)
        end
      end)

    assert match?({:error, %Postgrex.Error{postgres: %{code: :check_violation}}}, result),
           "resolution equality constraint accepted NULL finished_at: #{inspect(result)}"
  end

  test "MF2: stale maintenance messages wait for a pending settlement, then resume once it is definite",
       ctx do
    blocked = none!(ctx)
    latest = latest_start!(ctx)
    before = starts!(ctx)

    settlement = %{
      switch_id: blocked.id,
      attestation: attestation(blocked, latest, :none),
      resolver_id: ctx.admin.id
    }

    # The exact pending-settlement shape `unknown/2` retains (state
    # injection); this resolution never committed, so its settlement is a
    # definite :resolve_timeout once the barrier is taken.
    :sys.replace_state(Coordinator, &%{&1 | settling: settlement})

    for message <- [:boot, :replace, {:retry_block, blocked.id, "coordinator_restarted"}],
        do: send(Coordinator, message)

    sync()
    Process.sleep(1_500)
    sync()

    assert :sys.get_state(Coordinator).settling == settlement
    assert starts!(ctx) == before, "nothing allocated while the settlement is pending"
    assert Process.whereis(ClaudeCLI.server()) == nil, "nothing started while it is pending"

    # The settlement's own tick: barrier, exact re-read, definite.
    send(Coordinator, :settle)
    sync()
    assert :sys.get_state(Coordinator).settling == nil

    boot = status().boot_id

    await!(
      fn ->
        Enum.any?(starts!(ctx), &(&1.boot_id == boot and &1.generation > latest.generation))
      end,
      10_000,
      "the deferred boot retry resumed after the definite settlement"
    )

    assert switch!(ctx, blocked.id) == blocked
    assert status().hold != :released
    assert resolved_events(ctx) == []
  end
end

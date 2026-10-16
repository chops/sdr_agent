defmodule SdrAgent.AI.RuntimeStatusReviewTest do
  @moduledoc """
  C2-02c GREEN review regressions (Codex 5503795b,
  `codex-c202c-078aee7-green-review.md`; probe source
  `codex_c202c_078aee7_review_test.exs`, sha256 343fef08…, assertions
  unchanged):

    * MF1: a delayed block retry for older terminal history neither
      replaces a newer desired observation nor erases the current open
      switch;
    * MF2: a failed reconciliation read publishes `switch: :unknown`, never
      a retained confirmed-none;
    * MF3: an uncertain finalization keeps its `:finalizing` stage until its
      read settles.

  Shared SQL sandbox; the fake CLI under the test launcher; zero model
  calls.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @moduletag :c2_02c
  @moduletag timeout: 180_000

  setup do
    tenant = bootstrap!()
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  test "a delayed block retry for older completed history cannot replace the newer desired observation",
       ctx do
    SH.tree!()
    RH.await_status!(&(&1.hold == :released))
    old = completed_switch!(ctx)
    completed_switch!(ctx)
    assert %{profile_id: :claude_cli_opus} = Runtime.status().desired_profile

    # A stale maintenance message, not a persisted-row or state rewrite.
    send(Coordinator, {:retry_block, old.id, "operation_died"})
    RH.sync()
    actual = Runtime.status()
    assert %{profile_id: :claude_cli_opus} = actual.desired_profile
  end

  test "a delayed block retry for old terminal history cannot erase the current open switch",
       ctx do
    SH.tree!()
    RH.await_status!(&(&1.hold == :released))
    old = completed_switch!(ctx)
    pause = RH.pause_stage!(:drained)
    current = RH.request_switch!(ctx)
    assert_receive {:stage_paused, :drained, worker}, 20_000
    :telemetry.detach(pause)
    assert %{id: id, state: :open} = Runtime.status().switch
    assert id == current.id

    send(Coordinator, {:retry_block, old.id, "operation_died"})
    RH.sync()
    actual = Runtime.status()
    send(worker, :continue)
    assert %{id: ^id, state: :open} = actual.switch
  end

  test "a failed finalization reread publishes unknown rather than retaining a known-none claim",
       ctx do
    {:ok, gate} = Agent.start_link(fn -> :pause end)
    parent = self()

    callback = fn ->
      case Agent.get_and_update(gate, fn mode ->
             {mode, if(mode == :pause, do: :unavailable, else: mode)}
           end) do
        :pause ->
          send(parent, {:reconcile_paused, self()})

          receive do
            :codex_continue -> :read
          after
            10_000 -> :unavailable
          end

        mode ->
          mode
      end
    end

    SH.tree!(faults: [reconcile: callback])
    RH.await_status!(&(&1.hold == :released))
    switch = RH.request_switch!(ctx)
    assert_receive {:reconcile_paused, coordinator}, 20_000
    on_exit(fn -> send(coordinator, :codex_continue) end)
    assert RH.switch!(ctx, switch.id).status == :completed

    SH.break_table!("model_profile_switches")
    send(coordinator, :codex_continue)
    RH.sync()
    actual = Runtime.status()
    SH.restore_table!("model_profile_switches")
    Agent.update(gate, fn _ -> :read end)
    RH.await_status!(&(&1.hold == :released), 10_000)

    assert actual.switch == :unknown
  end

  defp completed_switch!(ctx) do
    switch = RH.request_switch!(ctx)
    RH.await_switch!(ctx, switch.id, :completed)
    RH.await_status!(&(&1.hold == :released), 20_000)
    RH.drain!()
    switch
  end

  test "uncertain finalization retains the finalizing stage until its read settles", ctx do
    {:ok, gate} = Agent.start_link(fn -> :unavailable end)
    SH.tree!(faults: [lose_reply: [:complete], reconcile: fn -> Agent.get(gate, & &1) end])
    RH.await_status!(&(&1.hold == :released))
    switch = RH.request_switch!(ctx)
    RH.await_switch!(ctx, switch.id, :completed)
    RH.await_status!(&(&1.hold == :held and is_nil(&1.switch_id)), 20_000)
    RH.drain!()
    actual = Runtime.status()
    Agent.update(gate, fn _ -> :read end)
    RH.await_status!(&(&1.hold == :released), 20_000)

    assert actual.switch == :unknown
    assert actual.desired_profile == :unknown
    assert actual.stage == :finalizing
  end
end

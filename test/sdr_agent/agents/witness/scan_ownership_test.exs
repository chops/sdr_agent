defmodule SdrAgent.Agents.Witness.ScanOwnershipTest do
  @moduledoc """
  R0-07 slice C, row G3 (with its section 6.4 bounds): a completed
  generation-2 ClaudeCLI invocation with no `ModelResultRelease` belongs
  to the result gate (running run) or to run recovery (terminal run). The
  scan neither schedules it nor writes for it: `Witness.reconcile/2`
  without `gate:` rechecks ownership right after its invocation `FOR
  UPDATE` lock and returns `{:ok, %{status: :deferred_to_gate}}`, writing
  no link and no attention. Once a release exists the scan backfills as
  before; generation-1 rows are unchanged.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.ScanWorker
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    root = GateFixtures.root!()
    on_exit(fn -> File.rm_rf!(root) end)
    %{run: run, agent: agent} = AgentsFixtures.operated_run(tenant)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      root: root,
      rec: system_actor(:reconciler, tenant),
      admin: human(:admin, tenant)
    }
  end

  defp scan(ctx, invocation),
    do: Witness.reconcile(invocation.id, actor: ctx.rec, store_root: ctx.root)

  defp links(ctx, invocation) do
    {:ok, links} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    links
  end

  defp attention(ctx, invocation) do
    {:ok, all} = Operations.list_attention(actor: ctx.admin)
    Enum.filter(all, &(&1.subject_id == invocation.id))
  end

  test "an unreleased generation-2 row of a running run is deferred; nothing written", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "own-1")

    assert {:ok, %{status: :deferred_to_gate}} = scan(ctx, invocation)
    assert links(ctx, invocation) == []
    assert attention(ctx, invocation) == []
  end

  test "an unreleased generation-2 row of a terminal run is deferred too", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "own-2")
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    {:ok, _} = Agents.cancel_run(run, actor: ctx.admin)

    assert {:ok, %{status: :deferred_to_gate}} = scan(ctx, invocation)
    assert links(ctx, invocation) == []
    assert attention(ctx, invocation) == []
  end

  test "once released or withheld the scan backfills", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "own-3")
    cause = GateFixtures.cause!(invocation, operation_id: ctx.run.operation_id)
    GateFixtures.withhold!(invocation, ctx.agent, cause)

    assert {:ok, %{status: status}} = scan(ctx, invocation)
    refute status == :deferred_to_gate
  end

  test "a generation-1 row is unchanged", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "own-4")

    tamper!(
      "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
        "allocation_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(invocation.id)]
    )

    assert {:ok, %{status: status}} = scan(ctx, invocation)
    refute status == :deferred_to_gate
  end

  describe "scheduling" do
    setup ctx do
      previous = Application.get_env(:sdr_agent, Witness, [])
      Application.put_env(:sdr_agent, Witness, Keyword.put(previous, :store_root, ctx.root))
      on_exit(fn -> Application.put_env(:sdr_agent, Witness, previous) end)
      :ok
    end

    test "the scan does not schedule an unreleased generation-2 row; it does once decided",
         ctx do
      invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "own-5")

      assert :ok = ScanWorker.perform(%Oban.Job{})
      assert {:ok, []} = Witness.operations(invocation.id, ctx.rec)

      cause = GateFixtures.cause!(invocation, operation_id: ctx.run.operation_id)
      GateFixtures.withhold!(invocation, ctx.agent, cause)

      assert :ok = ScanWorker.perform(%Oban.Job{})
      assert {:ok, [_generation_1]} = Witness.operations(invocation.id, ctx.rec)
    end
  end
end

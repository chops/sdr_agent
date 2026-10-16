defmodule SdrAgent.SDR.ProfileSwitchSettlementTest do
  @moduledoc """
  C2-02b1 (#52, slice b1), MF2 (`docs/product/r0/c2-02b1-interface.md`,
  "Operation settlement", PASS at cda8ee5): a run the drain stops
  `:model_not_admitted` has its still-running Operation failed by the
  worker's existing outcome rule. That is a shared domain-owned
  settlement, not an `Agents` → worker call. A retried drain finishes the
  obligation before it reports success. The stale-run sweeper heals a crash
  between the run-stop commit and the Operation's transaction once the job
  is dead. There is exactly one live attention item, and the
  resolved-cause rule applies.

  The crash is injected with a test trigger on `operations` (rolled back
  with the sandbox). RED: `drain_profile_switch/3` doesn't exist on the
  base; presence is asserted after the fixtures.
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Test.CoordinatorHarness
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.StaleRunSweeper

  setup ctx do
    # C2-02b2α: the switch finalizers run in the coordinator (manual mode).
    CoordinatorHarness.start!()
    AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    AdmissionFixtures.admit_tuples!()
    %{run: run, operation: operation, job: job} = assign!(ctx, "01")
    {:ok, operation} = Operations.start_operation(operation, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)

    {:ok, invocation} =
      Agents.reserve_model_invocation(
        run,
        "settle" |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"k":"settle"})),
        actor: ctx.agent
      )

    {:ok, switch} =
      Agents.request_profile_switch(
        %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: 1},
        actor: ctx.admin
      )

    %{
      run: run,
      operation: operation,
      job: job,
      invocation: invocation,
      switch: switch,
      runtime: system_actor(:model_runtime, ctx.tenant)
    }
  end

  defp drain(ctx) do
    assert function_exported?(Agents, :drain_profile_switch, 3),
           "C2-02b1: Agents.drain_profile_switch/3 is not implemented"

    Agents.drain_profile_switch(
      ctx.switch,
      %{server_generation: ctx.switch.server_generation, timeout_ms: 2_000},
      actor: ctx.agent
    )
  end

  defp operation!(ctx) do
    {:ok, operation} = Operations.get_operation(ctx.operation.id, actor: ctx.admin)
    operation
  end

  defp live_items(ctx) do
    {:ok, items} = Operations.list_attention(actor: ctx.admin)
    length(items)
  end

  defp kill_job!(ctx) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^ctx.job.id), set: [state: "discarded"])
  end

  # A crash after the run-stop commit, before the Operation's own
  # transaction: any Operation failure raises until `heal_crash!/0`.
  defp crash_operation_settlement! do
    Repo.query!("""
    CREATE FUNCTION sdr_test_crash_operation() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected operation crash'; END $$
    """)

    Repo.query!(
      "CREATE TRIGGER crash_operation BEFORE UPDATE ON operations FOR EACH ROW " <>
        "WHEN (NEW.status IN ('failed', 'discarded')) EXECUTE FUNCTION sdr_test_crash_operation()"
    )
  end

  defp heal_crash!, do: Repo.query!("DROP TRIGGER crash_operation ON operations")

  defp assert_settled_by_rule(ctx, cause_id) do
    run = run!(ctx, ctx.run)
    assert {run.status, run.status_reason} == {:failed, :model_not_admitted}
    operation = operation!(ctx)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == cause_id
    operation
  end

  test "a dead worker: the drain stops the run and fails its Operation on the cause", ctx do
    kill_job!(ctx)
    before = live_items(ctx)

    assert {:ok, %{refused: 1}} = drain(ctx)

    run = run!(ctx, ctx.run)
    assert_settled_by_rule(ctx, run.attention_failure_id)
    assert live_items(ctx) == before + 1
  end

  test "a crash after the run stop: a retried drain settles the Operation before success",
       ctx do
    kill_job!(ctx)
    crash_operation_settlement!()

    assert {:error, _} = drain(ctx)
    assert run!(ctx, ctx.run).status == :failed
    assert operation!(ctx).status == :running

    heal_crash!()
    assert {:ok, %{refused: 0}} = drain(ctx)
    assert_settled_by_rule(ctx, run!(ctx, ctx.run).attention_failure_id)
  end

  test "a crash after the run stop: the sweeper heals it once the job is dead", ctx do
    crash_operation_settlement!()
    assert {:error, _} = drain(ctx)
    heal_crash!()

    # A live job's Operation is left to its worker.
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert operation!(ctx).status == :running

    kill_job!(ctx)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert_settled_by_rule(ctx, run!(ctx, ctx.run).attention_failure_id)

    events = length(events(ctx.tenant))
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert length(events(ctx.tenant)) == events
  end

  test "a resolved cause: the Operation fails with its own Failure naming it", ctx do
    kill_job!(ctx)
    crash_operation_settlement!()
    assert {:error, _} = drain(ctx)

    run = run!(ctx, ctx.run)
    {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
    {:ok, _} = Operations.resolve_failure(cause, %{resolution_note: "seen"}, actor: ctx.admin)
    heal_crash!()

    assert {:ok, %{refused: 0}} = drain(ctx)
    operation = operation!(ctx)
    assert operation.status in [:failed, :discarded]
    refute operation.last_failure_id == cause.id
    {:ok, own} = Operations.get_failure(operation.last_failure_id, actor: ctx.admin)
    assert own.message =~ cause.id
    assert live_items(ctx) == 1
  end

  # A sequential replay of the worker's steps after the drain. The held
  # contention is in ProfileSwitchFenceRaceTest, and the worker's whole
  # producer path is in ProfileSwitchLateWorkerTest.
  test "a worker replaying after the drain settles nothing twice and opens no second item",
       ctx do
    assert {:ok, %{refused: 1}} = drain(ctx)
    run = run!(ctx, ctx.run)
    operation = operation!(ctx)
    items = live_items(ctx)

    # The worker's late launch of the refused row, then its own outcome.
    assert {:error, :invocation_not_reserved} =
             Agents.admit_launch(ctx.invocation.id, :claude_cli_opus, actor: ctx.agent)

    assert :ok = AgentWorker.fail_operation(operation, run, ctx.agent)

    assert live_items(ctx) == items
    assert operation!(ctx).last_failure_id == operation.last_failure_id
    assert run!(ctx, ctx.run).attention_failure_id == run.attention_failure_id
  end

  test "a reply-intake run (no Operation) is stopped, and no Operation is touched", ctx do
    # The reply row must be reserved while no switch is open: close the
    # setup's switch, reserve, then open a second one.
    {:ok, _} =
      CoordinatorHarness.finalize(
        :fail_profile_switch,
        ctx.switch,
        %{server_generation: 1, failure_reason: "test"},
        actor: ctx.runtime
      )

    %{run: reply_run} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :reply)

    assert {:ok, _row} =
             Agents.reserve_model_invocation(
               reply_run,
               "reply" |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"k":"reply"})),
               actor: ctx.agent
             )

    {:ok, second} =
      Agents.request_profile_switch(
        %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: 2},
        actor: ctx.admin
      )

    kill_job!(ctx)
    assert {:ok, %{refused: 2}} = drain(%{ctx | switch: second})
    {:ok, reply_run} = Agents.get_run(reply_run.id, actor: ctx.agent)
    assert {reply_run.status, reply_run.status_reason} == {:failed, :model_not_admitted}
    assert is_nil(reply_run.operation_id)
  end
end

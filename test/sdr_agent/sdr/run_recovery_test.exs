defmodule SdrAgent.SDR.RunRecoveryTest do
  @moduledoc """
  S13 crash recovery of agent runs (S7 choice 11/15, S9b review item 3): a
  worker process killed mid-run — here mid-model-call, the VM-crash case
  the worker cannot catch — leaves the AgentRun and its Operation
  `running` and the ModelInvocation `sent`. After a restart Oban's lifeline
  discards the orphaned job (agent jobs have one attempt), and
  `SdrAgent.SDR.StaleRunSweeper` recovers the run: the invocation becomes
  `unknown` (never re-sent, counted as used), the run fails with `crash`
  and its attention Failure, the Operation is failed and discarded linking
  that Failure. A run whose job is still live is left alone, and recovery
  is idempotent.
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]

  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.StaleRunSweeper

  defmodule BlockingResponder do
    @moduledoc "Test responder: reports the model call, then never answers."
    def respond(_operation, _input) do
      send(:persistent_term.get({__MODULE__, :test}), {:model_called, self()})
      Process.sleep(:infinity)
    end
  end

  # The killed worker ran in its own process, on the wall clock (the frozen
  # test clock is per process): move past the run's own start.
  defp past_stale_window(ctx, run) do
    started = run!(ctx, run).started_at
    Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))
  end

  # Runs the assignment's job in a process and kills it during the model call.
  defp crash_mid_model_call!(ctx) do
    :persistent_term.put({BlockingResponder, :test}, self())
    on_exit(fn -> :persistent_term.erase({BlockingResponder, :test}) end)

    %{run: run, operation: operation, job: job} =
      assign!(ctx, "01", model: [provider_options: [responder: BlockingResponder]])

    worker = spawn(fn -> AgentWorker.perform(job) end)
    assert_receive {:model_called, _caller}, 10_000
    Process.exit(worker, :kill)
    %{run: run, operation: operation, job: job}
  end

  # What Oban's lifeline does to an orphaned one-attempt job after a restart.
  defp lifeline_discards!(job) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
  end

  test "a run killed mid-model-call is recovered without re-sending anything", ctx do
    %{run: run, operation: operation, job: job} = crash_mid_model_call!(ctx)

    assert run!(ctx, run).status == :running
    assert [%{status: :sent} = invocation] = invocations!(ctx, run)

    lifeline_discards!(job)
    past_stale_window(ctx, run)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

    recovered = run!(ctx, run)
    assert {recovered.status, recovered.status_reason} == {:failed, :crash}
    assert recovered.failure_reason =~ "abandoned"
    assert [%{id: id, status: :unknown}] = invocations!(ctx, run)
    assert id == invocation.id

    {:ok, op} = Operations.get_operation(operation.id, actor: ctx.agent)
    assert op.status == :discarded
    assert op.last_failure_id == recovered.attention_failure_id

    {:ok, failure} = Operations.get_failure(recovered.attention_failure_id, actor: ctx.agent)
    assert failure.status == :open

    # Idempotent: a second sweep changes nothing.
    events = length(events(ctx.tenant))
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert length(events(ctx.tenant)) == events
    assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.aud)
  end

  test "a running run whose job is still live is left alone", ctx do
    %{run: run} = crash_mid_model_call!(ctx)

    # The job was never picked up by Oban (still available): not abandoned.
    past_stale_window(ctx, run)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

    assert run!(ctx, run).status == :running
    assert [%{status: :sent}] = invocations!(ctx, run)
  end

  test "a run running for less than the stale window is left alone", ctx do
    %{run: run, job: job} = crash_mid_model_call!(ctx)
    lifeline_discards!(job)

    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert run!(ctx, run).status == :running
  end

  test "the sweeper is a scheduled cron job" do
    {Oban.Plugins.Cron, opts} =
      :sdr_agent
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

    assert Enum.any?(opts[:crontab], &match?({_, StaleRunSweeper}, &1))
  end
end

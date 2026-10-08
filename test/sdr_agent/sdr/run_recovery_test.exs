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

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
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

  # Review #25 MF1 (Codex repro, adopted): the job turns live between the
  # sweep's first (unlocked) observation and recovery. Recovery must re-check
  # liveness under its locks and leave the run alone.
  for live <- ~w(available scheduled executing retryable) do
    test "a job turned #{live} after the first observation is not failed", ctx do
      %{run: run, operation: operation, job: job} = crash_mid_model_call!(ctx)
      lifeline_discards!(job)
      past_stale_window(ctx, run)
      parent = self()
      handler = "job-live-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = IO.iodata_to_binary(metadata.query)

          if self() != parent and String.starts_with?(query, "SELECT") and
               String.contains?(query, ~s(FROM "oban_jobs")) and
               String.contains?(query, "state") and
               not Process.get(:paused_job_query, false) do
            Process.put(:paused_job_query, true)
            send(parent, {:observed_discarded_job, self()})

            receive do
              :resume -> :ok
            after
              5_000 -> raise "barrier timed out"
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      sweep = Task.async(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end)
      assert_receive {:observed_discarded_job, sweep_pid}, 5_000

      {1, _} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: unquote(live)])

      send(sweep_pid, :resume)
      assert :ok = Task.await(sweep, 10_000)

      assert run!(ctx, run).status == :running
      assert [%{status: :sent}] = invocations!(ctx, run)
      assert {:ok, %{status: :running}} = Operations.get_operation(operation.id, actor: ctx.agent)
    end
  end

  test "a run whose job cannot be identified is skipped, not read as a missing job", ctx do
    %{run: run, operation: operation, job: job} = crash_mid_model_call!(ctx)
    lifeline_discards!(job)

    {1, _} =
      Repo.update_all(
        from(o in "operations", where: o.id == type(^operation.id, :binary_id)),
        set: [oban_job_id: nil]
      )

    past_stale_window(ctx, run)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert run!(ctx, run).status == :running
  end

  # Review #25 (lock order, ADR-0009): every row recovery writes — the run,
  # its Operation, the job and *all* its sent invocations — is locked before
  # the first audit append (the chain-head lock).
  test "recovery locks every row before its first append", ctx do
    %{run: run, job: job} = crash_mid_model_call!(ctx)
    {:ok, running} = Agents.get_run(run.id, actor: ctx.agent)

    {:ok, second} =
      Agents.reserve_model_invocation(running, AgentsFixtures.model_attrs("second"),
        actor: ctx.agent
      )

    {:ok, _} = Agents.mark_model_invocation_sent(second, actor: ctx.agent)
    lifeline_discards!(job)
    past_stale_window(ctx, run)

    queries = capture_queries(fn -> assert :ok = StaleRunSweeper.sweep(ctx.tenant.id) end)

    assert {run!(ctx, run).status, Enum.map(invocations!(ctx, run), & &1.status)} ==
             {:failed, [:unknown, :unknown]}

    first_append = Enum.find_index(queries, &String.contains?(&1, ~s("audit_chain_heads")))
    assert first_append

    for table <- ~w(agent_runs operations oban_jobs model_invocations) do
      locks = lock_indexes(queries, table)
      assert locks != [], "#{table} is never locked"
      assert Enum.min(locks) < first_append, "#{table} first locked after the first append"
    end

    # Both invocations are locked by one statement before any append.
    assert Enum.any?(Enum.take(queries, first_append), &invocations_prelock?/1)
  end

  test "settling a model call locks the run before its first append", ctx do
    %{run: run} = crash_mid_model_call!(ctx)
    [sent] = invocations!(ctx, run)

    queries =
      capture_queries(fn ->
        assert {:ok, _} =
                 Agents.fail_model_invocation(
                   sent,
                   %{error: %{"class" => "provider_error", "message" => "late failure"}},
                   actor: ctx.agent
                 )
      end)

    first_append = Enum.find_index(queries, &String.contains?(&1, ~s("audit_chain_heads")))
    assert first_append
    assert [run_lock | _] = lock_indexes(queries, "agent_runs")
    assert run_lock < first_append
  end

  defp capture_queries(fun) do
    parent = self()
    handler = "queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, IO.iodata_to_binary(metadata.query)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_queries([])
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp lock_indexes(queries, table) do
    for {query, index} <- Enum.with_index(queries),
        String.starts_with?(query, "SELECT"),
        String.contains?(query, ~s(FROM "#{table}")),
        String.contains?(query, "FOR UPDATE"),
        do: index
  end

  defp invocations_prelock?(query) do
    String.starts_with?(query, "SELECT") and String.contains?(query, ~s(FROM "model_invocations")) and
      String.contains?(query, "FOR UPDATE") and String.contains?(query, ~s("status"))
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

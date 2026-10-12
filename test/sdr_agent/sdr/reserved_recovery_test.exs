defmodule SdrAgent.SDR.ReservedRecoveryTest do
  @moduledoc """
  C9-03 recovery of abandoned, unlaunched reservations (R0 readiness packet,
  "C9-03 recovery delta", entity PASS by Codex 2026-10-12). A ClaudeCLI call
  now waits in the server's queue as `reserved`; a facade caller killed
  there never settles it. `SdrAgent.SDR.StaleRunSweeper` closes such rows
  reserved → failed (`sent_at` nil, never unknown), keeping the charged
  attempt and inventing no use:

    * (a) with the run it proves abandoned (stale, job not live, decided
      under its locks), together with that run's `sent` rows;
    * (b) of an already terminal run, when reserved strictly before the
      stale cutoff (a grace period); the run is not written.

  Live work (a live job, a fresh run, a recent reservation) is never
  touched, and a second sweep changes nothing.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock
  alias SdrAgent.SDR.StaleRunSweeper

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @t0 ~U[2026-10-20 12:00:00.000000Z]

  setup do
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    grant = AgentsFixtures.grant!(tenant, %{}, admin)
    %{tenant: tenant, admin: admin, grant: grant}
  end

  defp stale, do: StaleRunSweeper.stale_after_seconds()

  defp run!(ctx), do: AgentsFixtures.running_run(ctx.tenant)

  defp reserve!(%{run: run, agent: agent}, key) do
    attrs = key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"r":"#{key}"}))
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    invocation
  end

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)
  defp stored_run(%{run: run, agent: agent}), do: elem(Agents.get_run(run.id, actor: agent), 1)

  defp consumed(grant) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp assert_failed_unlaunched(id, reason) do
    row = stored(id)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert row.error == %{"kind" => "abandoned_before_launch", "reason" => reason}
    row
  end

  defp sweep_at(ctx, at) do
    Clock.freeze(at)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
  end

  describe "(a) a run proven abandoned" do
    test "a facade caller killed while its call is queued: the row is failed, never launched",
         ctx do
      dump = Path.join(System.tmp_dir!(), "sdr-recovery-#{System.unique_integer([:positive])}")
      on_exit(fn -> (dump <> ".*") |> Path.wildcard() |> Enum.each(&File.rm/1) end)

      {:ok, server} =
        ClaudeCLI.start_link(
          command: System.find_executable("elixir"),
          test_launcher: true,
          command_args: [@fake, "env_dump", dump, "1500"],
          timeout: 20_000
        )

      running = run!(ctx)
      queued = run!(ctx)
      first = Task.async(fn -> complete(running, "running", server) end)
      assert eventually(fn -> match?(%{status: :sent}, by_key(ctx, "running")) end)

      caller = spawn(fn -> complete(queued, "queued", server) end)
      assert eventually(fn -> by_key(ctx, "queued") != nil end)
      assert eventually(fn -> queued?(server, caller) end)
      Process.exit(caller, :kill)

      assert {:ok, _} = Task.await(first, 20_000)
      # The server drops the dead caller's request unlaunched at dequeue.
      _ = :sys.get_state(server, 10_000)
      orphan = by_key(ctx, "queued")
      assert {orphan.status, orphan.sent_at} == {:reserved, nil}
      assert length(Path.wildcard(dump <> ".*")) == 1

      charged = consumed(ctx.grant)
      before = stored_run(queued)
      sweep_at(ctx, DateTime.add(before.started_at, stale() + 1, :second))

      recovered = stored_run(queued)
      assert {recovered.status, recovered.status_reason} == {:failed, :crash}
      assert_failed_unlaunched(orphan.id, "run_abandoned")

      # The attempt stays charged; no use or tokens are invented.
      assert consumed(ctx.grant) == charged
      assert recovered.budget.model_calls_reserved == before.budget.model_calls_reserved
      assert recovered.budget.model_calls_used == before.budget.model_calls_used
      assert recovered.budget.tokens_used == before.budget.tokens_used
      assert length(Path.wildcard(dump <> ".*")) == 1
    end

    test "its sent rows become unknown and its reserved rows failed, in one recovery", ctx do
      run = run!(ctx)
      sent = reserve!(run, "sent")
      {:ok, _} = Agents.admit_launch(sent.id, :claude_cli_opus, actor: run.agent)
      reserved = reserve!(run, "reserved")

      sweep_at(ctx, DateTime.add(stored_run(run).started_at, stale() + 1, :second))

      assert stored(sent.id).status == :unknown
      assert_failed_unlaunched(reserved.id, "run_abandoned")
      assert stored_run(run).status == :failed

      # Idempotent: a second sweep changes nothing.
      count = length(events(ctx.tenant))
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert length(events(ctx.tenant)) == count
    end

    test "a run that is not yet stale, or whose job is live, keeps its reserved rows", ctx do
      live = run!(ctx)
      live_row = reserve!(live, "live")

      %Oban.Job{} =
        %{"run_id" => live.run.id}
        |> Oban.Job.new(worker: "SdrAgent.SDR.ReplyWorker", queue: :agent)
        |> Repo.insert!()

      fresh = run!(ctx)
      fresh_row = reserve!(fresh, "fresh")

      # Not yet stale: nothing is swept.
      sweep_at(ctx, DateTime.add(stored_run(fresh).started_at, stale() - 60, :second))
      assert {stored(fresh_row.id).status, stored_run(fresh).status} == {:reserved, :running}

      # Stale, but the live job keeps its run (and its queued call) alone.
      sweep_at(ctx, DateTime.add(stored_run(live).started_at, stale() + 1, :second))
      assert {stored(live_row.id).status, stored_run(live).status} == {:reserved, :running}
    end
  end

  describe "(b) an already terminal run" do
    defp stop!(ctx, run, :cancelled), do: Agents.cancel_run(run.run, actor: ctx.admin)
    defp stop!(_ctx, run, :succeeded), do: Agents.succeed_run(run.run, actor: run.agent)

    defp stop!(_ctx, run, :failed),
      do:
        Agents.fail_run(run.run, %{status_reason: :crash, failure_reason: "x"}, actor: run.agent)

    defp stop!(_ctx, run, :budget_exhausted),
      do:
        Agents.exhaust_run_budget(run.run, %{status_reason: :run_budget_tokens}, actor: run.agent)

    test "a reservation older than the cutoff is failed; the run is not written", ctx do
      for status <- [:cancelled, :succeeded, :failed, :budget_exhausted] do
        Clock.freeze(@t0)
        run = run!(ctx)
        old = reserve!(run, "old-#{status}")
        Clock.freeze(DateTime.add(@t0, 60, :second))
        recent = reserve!(run, "recent-#{status}")
        {:ok, _} = stop!(ctx, run, status)
        stopped = stored_run(run)
        assert stopped.status == status
        charged = consumed(ctx.grant)

        # Exactly at the cutoff (reserved_at == now - stale): untouched.
        sweep_at(ctx, DateTime.add(@t0, stale(), :second))
        assert stored(old.id).status == :reserved

        # Strictly older than the cutoff: failed; the recent row is untouched.
        sweep_at(ctx, DateTime.add(DateTime.add(@t0, stale(), :second), 1, :microsecond))
        assert_failed_unlaunched(old.id, "run_stopped")
        assert stored(recent.id).status == :reserved

        after_sweep = stored_run(run)
        assert after_sweep.status == status
        assert after_sweep.status_reason == stopped.status_reason
        assert after_sweep.attention_failure_id == stopped.attention_failure_id
        assert after_sweep.finished_at == stopped.finished_at
        assert after_sweep.budget == stopped.budget
        assert consumed(ctx.grant) == charged

        # A later pass still finds the (now old) row of the terminal run.
        sweep_at(ctx, DateTime.add(@t0, stale() + 61, :second))
        assert_failed_unlaunched(recent.id, "run_stopped")

        count = length(events(ctx.tenant))
        assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
        assert length(events(ctx.tenant)) == count
      end
    end

    test "a queued (never started) run's reservations are not swept", ctx do
      agent = system_actor(:agent_runtime, ctx.tenant)
      definition = AgentsFixtures.definition!(ctx.tenant)
      {:ok, queued} = Agents.create_run(AgentsFixtures.run_attrs(definition), actor: agent)

      Clock.freeze(@t0)
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert {:ok, %{status: :queued}} = Agents.get_run(queued.id, actor: agent)
    end
  end

  describe "lock order (run first, as launch admission)" do
    test "both cases lock the run, then the invocations, before the first append", ctx do
      abandoned = run!(ctx)
      reserve!(abandoned, "lock-a")
      Clock.freeze(@t0)
      stopped = run!(ctx)
      reserve!(stopped, "lock-b")
      {:ok, _} = stop!(ctx, stopped, :cancelled)

      at =
        Enum.max(
          [
            DateTime.add(stored_run(abandoned).started_at, stale() + 1, :second),
            DateTime.add(@t0, stale() + 1, :second)
          ],
          DateTime
        )

      Clock.freeze(at)
      queries = capture_queries(fn -> assert :ok = StaleRunSweeper.sweep(ctx.tenant.id) end)

      appends =
        for {q, i} <- Enum.with_index(queries),
            String.contains?(q, ~s("audit_chain_heads")),
            do: i

      run_locks = lock_indexes(queries, "agent_runs")
      invocation_locks = lock_indexes(queries, "model_invocations")
      assert length(invocation_locks) >= 2, "each recovery locks its invocations"

      # Each invocation lock follows a run lock with no append between them,
      # and precedes an append.
      for invocation_lock <- invocation_locks do
        run_lock = run_locks |> Enum.filter(&(&1 < invocation_lock)) |> Enum.max(fn -> nil end)
        assert run_lock, "an invocation is locked before its run"
        refute Enum.any?(appends, &(&1 > run_lock and &1 < invocation_lock))
        assert Enum.any?(appends, &(&1 > invocation_lock))
      end

      assert stored_run(abandoned).status == :failed
    end
  end

  defp complete(run, id, server) do
    audit =
      id
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    ModelProvider.complete(
      %{
        id: id,
        run: run.run,
        actor: run.agent,
        operation: "model.complete",
        prompt: "Qualify the fixture lead",
        schema: @schema,
        audit: audit
      },
      provider: ClaudeCLI,
      provider_options: [server: server]
    )
  end

  defp by_key(ctx, key) do
    ModelInvocation
    |> Ash.Query.filter(idempotency_key == ^key and tenant_id == ^ctx.tenant.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp queued?(server, pid) do
    {:messages, messages} = Process.info(server, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^pid, _tag}, _request}, &1))
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

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

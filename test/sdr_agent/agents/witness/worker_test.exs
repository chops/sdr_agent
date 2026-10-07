defmodule SdrAgent.Agents.Witness.WorkerTest do
  @moduledoc """
  S12c step 6 scheduling (R2, C8): reconciliation runs as Oban jobs on the
  `reconciliation` queue (concurrency 1) with a `reconcile_model` Operation
  written in the same transaction (outbox); the bounded maintenance scan
  enqueues each terminal ClaudeCLI invocation once, and only when a witness
  store is configured. Bounded attempts; never re-sends a model call.
  """
  use SdrAgent.AuditCase, async: false
  use Oban.Testing, repo: SdrAgent.Repo

  require Ash.Query

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @witness SdrAgent.Agents.Witness
  @reconcile_worker SdrAgent.Agents.Witness.ReconcileWorker
  @scan_worker SdrAgent.Agents.Witness.ScanWorker

  setup do
    tenant = bootstrap!()
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    previous = Application.get_env(:sdr_agent, @witness)
    on_exit(fn -> restore(previous) end)

    %{tenant: tenant, run: run, agent: agent, rec: system_actor(:reconciler, tenant)}
  end

  test "the reconciliation queue runs one job at a time (C8)" do
    queues = Application.fetch_env!(:sdr_agent, Oban) |> Keyword.fetch!(:queues)
    assert Keyword.get(queues, :reconciliation) == 1
  end

  test "enqueue writes one job and its reconcile_model Operation, idempotently", ctx do
    invocation = claude_invocation!(ctx, "enqueue-1")

    assert {:ok, %Operation{} = operation} = enqueue(invocation, ctx.rec)
    assert {operation.kind, operation.queue} == {:reconcile_model, :reconciliation}
    assert operation.subject_id == invocation.id
    assert operation.max_attempts == 3

    assert [job] = all_enqueued(worker: @reconcile_worker)
    assert job.id == operation.oban_job_id
    assert job.queue == "reconciliation"
    assert job.args["model_invocation_id"] == invocation.id

    assert {:ok, again} = enqueue(invocation, ctx.rec)
    assert again.id == operation.id
    assert length(all_enqueued(worker: @reconcile_worker)) == 1

    assert {:error, %Ash.Error.Forbidden{}} = enqueue(invocation, ctx.agent)
  end

  test "the worker reconciles and settles its Operation", ctx do
    root =
      Path.join(System.tmp_dir!(), "sdr-witness-worker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Application.put_env(:sdr_agent, @witness, store_root: root, reconciled_methods: [])

    invocation = claude_invocation!(ctx, "worker-1")
    assert {:ok, operation} = enqueue(invocation, ctx.rec)
    [job] = all_enqueued(worker: @reconcile_worker)

    assert :ok = perform(@reconcile_worker, job.args, id: job.id)
    {:ok, settled} = SdrAgent.Operations.get_operation(operation.id, actor: ctx.rec)
    assert settled.status == :succeeded
    # No store records for this invocation: unwitnessed with warning attention.
    assert {:ok, :unwitnessed} = Agents.witness_status(invocation.id, actor: ctx.rec)
  end

  test "the scan enqueues terminal ClaudeCLI invocations once, only when configured", ctx do
    claude = claude_invocation!(ctx, "scan-claude")
    _fake = fake_invocation!(ctx, "scan-fake")

    Application.put_env(:sdr_agent, @witness, store_root: nil, reconciled_methods: [])
    assert :ok = perform(@scan_worker, %{})
    assert all_enqueued(worker: @reconcile_worker) == []

    Application.put_env(:sdr_agent, @witness,
      store_root: System.tmp_dir!(),
      reconciled_methods: []
    )

    assert :ok = perform(@scan_worker, %{})
    assert :ok = perform(@scan_worker, %{})

    assert [job] = all_enqueued(worker: @reconcile_worker)
    assert job.args["model_invocation_id"] == claude.id
  end

  describe "bounded recovery (re-drive) of missing or open witnesses" do
    setup ctx do
      root =
        Path.join(System.tmp_dir!(), "sdr-witness-redrive-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      Application.put_env(:sdr_agent, @witness, store_root: root, reconciled_methods: [])
      start = ~U[2026-10-07 12:00:00.000000Z]
      SdrAgent.Clock.freeze(start)
      on_exit(fn -> SdrAgent.Clock.unfreeze() end)
      Map.merge(ctx, %{root: root, start: start})
    end

    test "a witness that appears later is reconciled by the next eligible pass", ctx do
      invocation = claude_invocation!(ctx, "late-1")
      sent = length(events_of_type(ctx.tenant, "model.invocation.sent"))

      assert :ok = perform(@scan_worker, %{})
      assert [first] = all_enqueued(worker: @reconcile_worker)
      assert :ok = perform(@reconcile_worker, first.args, id: first.id)
      assert [%{severity: :warning} = warning] = live_attention(ctx, invocation)

      # The Operation succeeded, but the missing-witness warning stays live.
      assert {:ok, [op]} = reconcile_operations(ctx, invocation)
      assert op.status == :succeeded

      # The proxy's final record lands afterwards.
      Proxy.exchange!(ctx.root, invocation.id, request: "{}", response: "{}")

      # Not yet eligible: re-drive waits a bounded interval after the last pass.
      assert :ok = perform(@scan_worker, %{})
      assert length(all_enqueued(worker: @reconcile_worker)) == 1

      SdrAgent.Clock.freeze(DateTime.add(ctx.start, 11, :minute))
      assert :ok = perform(@scan_worker, %{})
      assert :ok = perform(@scan_worker, %{})
      jobs = all_enqueued(worker: @reconcile_worker)
      assert length(jobs) == 2
      second = Enum.find(jobs, &(&1.id != first.id))
      assert :ok = perform(@reconcile_worker, second.args, id: second.id)

      assert {:ok, [_link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
      refute Enum.any?(live_attention(ctx, invocation), &(&1.id == warning.id))
      assert length(events_of_type(ctx.tenant, "model.invocation.sent")) == sent
      assert {:ok, ops} = reconcile_operations(ctx, invocation)
      assert length(ops) == 2
    end

    test "re-drives stop after a bounded number of passes", ctx do
      invocation = claude_invocation!(ctx, "late-2")

      for minute <- Enum.map(0..20, &(&1 * 11)) do
        SdrAgent.Clock.freeze(DateTime.add(ctx.start, minute, :minute))
        assert :ok = perform(@scan_worker, %{})

        for job <- all_enqueued(worker: @reconcile_worker), job.state == "available" do
          perform(@reconcile_worker, job.args, id: job.id)
        end
      end

      assert {:ok, ops} = reconcile_operations(ctx, invocation)
      assert length(ops) in 2..6
      assert [_one_warning] = live_attention(ctx, invocation)
    end

    test "a failing attempt fails its Operation truthfully, retries, then discards", ctx do
      invocation = claude_invocation!(ctx, "retry-1")
      Proxy.exchange!(ctx.root, invocation.id, request: "{}", response: "{}")
      assert {:ok, operation} = enqueue(invocation, ctx.rec)
      [job] = all_enqueued(worker: @reconcile_worker)
      refuse_access_inserts!()

      for attempt <- 1..3 do
        assert {:error, _} =
                 perform(@reconcile_worker, job.args,
                   id: job.id,
                   attempt: attempt,
                   max_attempts: 3
                 )

        {:ok, op} = SdrAgent.Operations.get_operation(operation.id, actor: ctx.rec)
        assert op.attempts == attempt
        assert op.status == if(attempt < 3, do: :failed, else: :discarded)
      end

      assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
    end
  end

  defp live_attention(ctx, invocation) do
    {:ok, failures} = SdrAgent.Operations.list_attention(actor: human(:admin, ctx.tenant))

    Enum.filter(
      failures,
      &(&1.subject_id == invocation.id and &1.class == :reconciliation_required)
    )
  end

  defp reconcile_operations(ctx, invocation) do
    Operation
    |> Ash.Query.for_read(:read, %{}, actor: ctx.rec)
    |> Ash.Query.filter(kind == :reconcile_model and subject_id == ^invocation.id)
    |> Ash.read()
  end

  defp refuse_access_inserts! do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE FUNCTION s12c_refuse_access() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'access store unavailable'; END; $$
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER s12c_refuse_access BEFORE INSERT ON audit_accesses " <>
        "FOR EACH ROW EXECUTE FUNCTION s12c_refuse_access()"
    )
  end

  defp claude_invocation!(ctx, key), do: invocation!(ctx, key, :claude_cli)
  defp fake_invocation!(ctx, key), do: invocation!(ctx, key, :fake)

  defp invocation!(ctx, key, provider) do
    attrs = AgentsFixtures.model_attrs(key) |> Map.put(:provider, provider)
    {:ok, invocation} = Agents.reserve_model_invocation(ctx.run, attrs, actor: ctx.agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: ctx.agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: ctx.agent)

    invocation
  end

  defp enqueue(invocation, actor) do
    if Code.ensure_loaded?(@witness) and function_exported?(@witness, :enqueue, 2),
      do: @witness.enqueue(invocation.id, actor: actor),
      else: {:error, {:not_implemented, :enqueue}}
  end

  defp perform(worker, args, opts \\ []) do
    if Code.ensure_loaded?(worker),
      do: perform_job(worker, args, opts),
      else: {:error, {:not_implemented, worker}}
  end

  defp restore(nil), do: Application.delete_env(:sdr_agent, @witness)
  defp restore(previous), do: Application.put_env(:sdr_agent, @witness, previous)
end

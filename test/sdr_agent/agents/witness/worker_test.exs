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

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Operations.Operation

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

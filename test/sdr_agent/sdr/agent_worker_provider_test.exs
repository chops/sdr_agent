defmodule SdrAgent.SDR.AgentWorkerProviderTest do
  @moduledoc """
  Q0.1: the agent worker runs on the runtime-selected provider. With
  ClaudeCLI selected (the default path) or carried by the job, every model
  call goes through the one supervised, named ClaudeCLI server (here backed
  by the hermetic fake CLI); when that server is not running the run fails
  with an explicit `provider_not_running`, a critical operator-attention
  Failure and no model call — never a raise and never a fallback to Fake.
  The Fake default is unchanged.

  R0-07 slice C: every generation-2 ClaudeCLI output passes the result
  gate before the run sees it. With a matching witness capture (the fake
  CLI playing shim and proxy) each output is released and the run
  succeeds; with the witness store unconfigured the first output is
  withheld (`:store_unreadable`), the run stops `:witness_unreconciled` on
  its gate cause, and the Operation fails linking that cause — never a
  crash, never a success.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.StaleRunSweeper

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  # C9: real-model (ClaudeCLI) reservations are charged to a grant.
  setup ctx do
    SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    :ok
  end

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  defp start_named!(args \\ []) do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       test_launcher: true,
       command_args: [@fake, "sdr" | args]}
    )
  end

  # A trusted stand-in witness store with the exact v3 Opus tuple enabled;
  # the fake CLI records a matching capture of every call under it.
  defp witnessed!(variant \\ "cli_shape_v3") do
    root = SdrAgent.Test.WitnessRoot.mkdir!("worker")
    previous = Application.get_env(:sdr_agent, SdrAgent.Agents.Witness, [])

    Application.put_env(
      :sdr_agent,
      SdrAgent.Agents.Witness,
      Keyword.merge(previous, store_root: root, reconciled_methods: [@v3_opus])
    )

    on_exit(fn ->
      Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous)
      File.rm_rf!(root)
    end)

    start_named!([root, variant])
  end

  # Test-seam builds only: runs `fun` on the completed invocation before the
  # gate step (`SdrAgent.Agents.ResultGate`).
  defp before_gate!(fun) do
    previous = Application.get_env(:sdr_agent, ResultGate, [])
    Application.put_env(:sdr_agent, ResultGate, Keyword.put(previous, :before_gate, fun))
    on_exit(fn -> Application.put_env(:sdr_agent, ResultGate, previous) end)
  end

  defp refute_crash(ctx) do
    refute Enum.any?(
             events_of_type(ctx.tenant, "agents.run.failed"),
             &(&1.payload["changes"]["status_reason"] == "crash")
           )
  end

  defp release!(ctx, invocation) do
    {:ok, release} = Agents.get_result_release(invocation.id, actor: ctx.agent)
    release
  end

  defp assert_claude_run(ctx, run, operation) do
    run = run!(ctx, run)
    assert run.status == :succeeded, inspect({run.status_reason, run.failure_reason})

    invocations = invocations!(ctx, run)
    assert [_ | _] = invocations
    assert Enum.all?(invocations, &(&1.provider == :claude_cli))
    assert Enum.all?(invocations, &(&1.model_id == "claude-opus-5-5"))
    assert Enum.all?(invocations, &(&1.status == :completed))
    assert Enum.all?(invocations, &match?(%{disposition: :released}, release!(ctx, &1)))

    assert {:ok, %{status: :succeeded}} = Operations.get_operation(operation.id, actor: ctx.admin)
  end

  defp assert_refused(ctx, run, operation) do
    run = run!(ctx, run)
    assert run.status == :failed
    assert run.status_reason == :provider_error
    assert run.failure_reason =~ "not running"
    assert invocations!(ctx, run) == []

    assert {:ok, failure} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
    assert failure.severity == :critical
    assert failure.status == :open

    assert {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == run.attention_failure_id
  end

  describe "ClaudeCLI selected at runtime (default path)" do
    setup do
      put_env!(:model_provider, ClaudeCLI)
      :ok
    end

    test "a run succeeds end-to-end through the named server", ctx do
      witnessed!()
      %{run: run, operation: operation} = assign!(ctx, "01")

      assert %{success: 1} = drain!()
      assert_claude_run(ctx, run, operation)
    end

    test "an unconfigured witness store withholds the output; the run stops", ctx do
      start_named!()
      %{run: run, operation: operation} = assign!(ctx, "01")

      assert %{success: 1} = drain!()
      run = run!(ctx, run)

      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled},
             run.failure_reason

      assert [invocation] = invocations!(ctx, run)
      release = release!(ctx, invocation)
      assert {release.disposition, release.reason} == {:withheld, :store_unreadable}

      {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)

      assert {cause.class, cause.subject_id, cause.operation_id} ==
               {:reconciliation_required, invocation.id, operation.id}

      assert {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
      assert operation.status in [:failed, :discarded]
      assert operation.last_failure_id == cause.id
      refute Enum.any?(decisions!(ctx, run), &(&1.model_invocation_id == invocation.id))
    end

    # Review MF5: a competitor decided withheld first (bound cause, run
    # still running); the run stops on that cause, never as a crash.
    test "a competitor's withheld release stops the run on its bound cause", ctx do
      witnessed!()
      parent = self()

      before_gate!(fn invocation ->
        {:ok, run} = Agents.get_run(invocation.agent_run_id, actor: ctx.agent)
        cause = GateFixtures.cause!(invocation, operation_id: run.operation_id)
        GateFixtures.withhold!(invocation, ctx.agent, cause)
        send(parent, {:competing, cause.id})
      end)

      %{run: run, operation: operation} = assign!(ctx, "01")
      assert %{success: 1} = drain!()
      assert_received {:competing, cause_id}

      stopped = run!(ctx, run)
      assert {stopped.status, stopped.status_reason} == {:failed, :witness_unreconciled}
      assert stopped.attention_failure_id == cause_id
      assert [_one] = invocations!(ctx, run)
      {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
      assert operation.last_failure_id == cause_id
      refute_crash(ctx)
    end

    # Interpretation 1 (accepted): a gate that cannot commit returns no
    # output; the run is neither a success nor a crash and is recovered later.
    test "a gate that cannot commit: no output, no success or crash; recovered later", ctx do
      witnessed!("cli_shape_v3_mismatch")
      parent = self()

      # A pre-existing scan critical without the run's Operation: the gate's
      # mismatch has no usable cause (row R7-2).
      before_gate!(fn invocation ->
        send(parent, {:stray, GateFixtures.cause!(invocation, severity: :critical)})
      end)

      %{run: run, operation: operation} = assign!(ctx, "01")
      assert %{success: 1} = drain!()
      assert_received {:stray, stray}

      assert run!(ctx, run).status == :running
      assert [invocation] = invocations!(ctx, run)
      assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: ctx.agent)
      assert {:ok, %{status: :running}} = Operations.get_operation(operation.id, actor: ctx.admin)
      refute_crash(ctx)

      {:ok, _} = Operations.resolve_failure(stray, %{resolution_note: "seen"}, actor: ctx.admin)
      started = run!(ctx, run).started_at
      Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

      run = run!(ctx, run)
      assert {run.status, run.status_reason} == {:failed, :witness_mismatch}
      refute run.attention_failure_id == stray.id
      assert release!(ctx, invocation).reason == :witness_mismatch
      {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
      assert operation.last_failure_id == run.attention_failure_id
      refute_crash(ctx)
    end

    test "with the server missing the run fails with provider_not_running", ctx do
      %{run: run, operation: operation} = assign!(ctx, "01")
      [job] = all_enqueued(worker: AgentWorker)

      assert {:error, :provider_not_running} = AgentWorker.perform(job)
      assert_refused(ctx, run, operation)
    end
  end

  describe "ClaudeCLI carried by the job (Fake selected)" do
    test "a run succeeds end-to-end through the named server", ctx do
      witnessed!()
      %{run: run, operation: operation} = assign!(ctx, "01", model: [provider: ClaudeCLI])

      assert %{success: 1} = drain!()
      assert_claude_run(ctx, run, operation)
    end

    test "with the server missing it is refused, never run on the Fake", ctx do
      %{run: run, operation: operation} = assign!(ctx, "01", model: [provider: ClaudeCLI])

      assert %{discard: 1, success: 0} = drain!()
      assert_refused(ctx, run, operation)
    end
  end

  test "an unknown model outcome fails the run once and is never re-sent", ctx do
    prefix = Path.join(System.tmp_dir!(), "sdr-claude-hang-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for record <- Path.wildcard(prefix <> ".*") do
        launch = record |> File.read!() |> JSON.decode!()

        for pid <- [launch["child"], launch["root"]],
            do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        File.rm(record)
      end
    end)

    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       test_launcher: true,
       command_args: [@fake, "hang", prefix],
       timeout: 1_500}
    )

    %{run: run} = assign!(ctx, "01", model: [provider: ClaudeCLI])
    assert %{success: 1} = drain!()

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :provider_error}
    assert [invocation] = invocations!(ctx, run)
    assert invocation.status == :unknown

    # Nothing is retried or re-sent: no job is left, no second launch.
    assert %{success: 0, failure: 0, discard: 0} = drain!()
    assert [_one] = invocations!(ctx, run)
    assert length(Path.wildcard(prefix <> ".*")) == 1
  end

  test "a job naming an unknown provider is refused, never run on the Fake", ctx do
    %{run: run, operation: operation} = assign!(ctx, "01", model: [provider: ClaudeCLI])
    [job] = all_enqueued(worker: AgentWorker)
    job = %{job | args: put_in(job.args, ["model", "provider"], "codex_app_server")}

    assert {:error, :unknown_model_provider} = AgentWorker.perform(job)

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :provider_error}
    assert run.failure_reason =~ "unknown model provider"
    assert invocations!(ctx, run) == []

    assert {:ok, %{last_failure_id: failure_id}} =
             Operations.get_operation(operation.id, actor: ctx.admin)

    assert failure_id == run.attention_failure_id
  end

  test "the Fake default is unchanged and needs no server", ctx do
    assert Application.fetch_env!(:sdr_agent, :model_provider) == Fake
    refute GenServer.whereis(ClaudeCLI.server())
    %{run: run} = assign!(ctx, "01")

    assert %{success: 1} = drain!()
    run = run!(ctx, run)
    assert run.status == :succeeded
    assert Enum.all?(invocations!(ctx, run), &(&1.provider == :fake))
  end
end

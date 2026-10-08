defmodule SdrAgent.SDR.AgentWorkerProviderTest do
  @moduledoc """
  Q0.1: the agent worker runs on the runtime-selected provider. With
  ClaudeCLI selected (the default path) or carried by the job, every model
  call goes through the one supervised, named ClaudeCLI server (here backed
  by the hermetic fake CLI); when that server is not running the run fails
  with an explicit `provider_not_running`, a critical operator-attention
  Failure and no model call — never a raise and never a fallback to Fake.
  The Fake default is unchanged.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  defp start_named! do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: [@fake, "sdr"]}
    )
  end

  defp assert_claude_run(ctx, run, operation) do
    run = run!(ctx, run)
    assert run.status == :succeeded, inspect({run.status_reason, run.failure_reason})

    invocations = invocations!(ctx, run)
    assert [_ | _] = invocations
    assert Enum.all?(invocations, &(&1.provider == :claude_cli))
    assert Enum.all?(invocations, &(&1.model_id == "claude-opus-5-5"))
    assert Enum.all?(invocations, &(&1.status == :completed))

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
      start_named!()
      %{run: run, operation: operation} = assign!(ctx, "01")

      assert %{success: 1} = drain!()
      assert_claude_run(ctx, run, operation)
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
      start_named!()
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

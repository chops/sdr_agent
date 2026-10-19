defmodule SdrAgent.SDR.RetryBindingTest do
  @moduledoc """
  C1-03 B RED worker-boundary assertions. Actual domain-created retries
  receive the reviewed marker as explicit synthetic fixture setup, so the
  real perform paths can be tested before the gateway exists. No real CLI
  is started; selecting ClaudeCLI must refuse before calling any model.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxRetryFixtures
  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations

  for {trigger, entry} <- [{:assignment, :perform}, {:assignment, :run}, {:reply, :perform}] do
    @trigger trigger
    @entry entry

    describe "#{trigger} #{entry}" do
      setup ctx do
        prior = prior!(ctx, @trigger)
        retry = queued_retry!(ctx, prior)
        %{prior: prior, retry: retry, entry: @entry}
      end

      test "known-terminal gen2 Fake input is a positive control", ctx do
        assert perform(ctx.retry.job, ctx.entry) == :ok
        assert run!(ctx, ctx.retry.run).status == :succeeded
        assert [_ | _] = invocations!(ctx, ctx.retry.run)
      end

      test "Fake-to-ClaudeCLI after enqueue refuses before any invocation", ctx do
        put_env!(:model_provider, ClaudeCLI)
        assert perform(ctx.retry.job, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
      end

      test "selected Fake cannot excuse a normally resolved real model", ctx do
        put_env!(SdrAgent.SDR, model: [provider: ClaudeCLI])
        assert perform(ctx.retry.job, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
      end

      test "a nonexistent actual job cannot mutate the stamp's guessed run", ctx do
        before = effects!(ctx)
        nonexistent = %{ctx.retry.job | id: 0}
        assert perform(nonexistent, ctx.entry) == {:error, :retry_binding_refused}
        assert effects!(ctx) == before
        assert run!(ctx, ctx.retry.run).status == :queued
      end

      for {field, value} <- [
            {"version", 2},
            {"expected_provider", "claude_cli"},
            {"run_id", "00000000-0000-4000-8000-000000000001"},
            {"retry_of_id", "00000000-0000-4000-8000-000000000002"},
            {"extra", "not-a-provider-override"}
          ] do
        test "persisted #{field} corruption refuses the actual bound run", ctx do
          args =
            Map.update!(ctx.retry.job.args, "c1_retry_binding", fn stamp ->
              Map.put(stamp, unquote(field), unquote(value))
            end)

          assert {:ok, job} = Oban.update_job(ctx.retry.job, %{args: args})
          assert perform(job, ctx.entry) == {:error, :retry_binding_refused}
          assert_refused!(ctx)
        end
      end

      for invalid <- [nil, false, "fake", %{}, %{"version" => 1}] do
        test "malformed persisted marker #{inspect(invalid)} is never legacy", ctx do
          args = Map.put(ctx.retry.job.args, "c1_retry_binding", unquote(Macro.escape(invalid)))
          assert {:ok, job} = Oban.update_job(ctx.retry.job, %{args: args})
          assert perform(job, ctx.entry) == {:error, :retry_binding_refused}
          assert_refused!(ctx)
        end
      end

      test "omitting only the passed stamp cannot evade the persisted stamp", ctx do
        passed = %{ctx.retry.job | args: Map.delete(ctx.retry.job.args, "c1_retry_binding")}
        assert perform(passed, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
      end

      test "a job model override is refused even if it names Fake", ctx do
        args = Map.put(ctx.retry.job.args, "model", %{"provider" => "fake"})
        assert {:ok, job} = Oban.update_job(ctx.retry.job, %{args: args})
        assert perform(job, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
      end

      test "a responder override refuses before parsing the module name", ctx do
        args =
          Map.put(ctx.retry.job.args, "model", %{
            "provider" => "fake",
            "responder" => "C103SyntheticNeverLoadedResponder"
          })

        assert {:ok, job} = Oban.update_job(ctx.retry.job, %{args: args})
        assert perform(job, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
      end

      test "duplicate terminal perform opens no second attention cause", ctx do
        put_env!(:model_provider, ClaudeCLI)
        assert perform(ctx.retry.job, ctx.entry) == {:error, :retry_binding_refused}
        assert_refused!(ctx)
        before = effects!(ctx)
        perform(ctx.retry.job, ctx.entry)
        assert effects!(ctx) == before
      end
    end
  end

  for trigger <- [:assignment, :reply] do
    test "unmarked legacy #{trigger} jobs preserve their existing behavior", ctx do
      prior = prior!(ctx, unquote(trigger))
      retry = queued_retry!(ctx, prior, false)
      refute Map.has_key?(retry.job.args, "c1_retry_binding")
      assert perform(retry.job) == :ok
      assert run!(ctx, retry.run).status == :succeeded
    end

    test "a refused marked #{trigger} job is discarded, not automatically retried", ctx do
      prior = prior!(ctx, unquote(trigger))
      retry = queued_retry!(ctx, prior)
      put_env!(:model_provider, ClaudeCLI)
      queue = if unquote(trigger) == :assignment, do: :research, else: :agent
      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: queue, with_safety: false)

      assert %Oban.Job{state: "discarded", attempt: 1, max_attempts: 1} =
               Repo.get(Oban.Job, retry.job.id)

      assert_refused!(Map.merge(ctx, %{prior: prior, retry: retry}))
    end
  end

  defp assert_refused!(ctx) do
    run = run!(ctx, ctx.retry.run)

    assert {run.status, run.status_reason, run.failure_reason} ==
             {:failed, :provider_error, "retry_binding_refused"}

    assert invocations!(ctx, run) == []
    assert {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
    assert {cause.class, cause.severity, cause.status} == {:run_stopped, :critical, :open}
    assert {cause.subject_resource, cause.subject_id} == {"SdrAgent.Agents.AgentRun", run.id}

    assert {:ok, original} =
             Operations.get_failure(ctx.prior.attention_failure_id, actor: ctx.admin)

    assert original.status == :resolved
    refute original.id == cause.id

    if run.operation_id do
      assert {:ok, operation} = Operations.get_operation(run.operation_id, actor: ctx.admin)
      assert operation.status in [:failed, :discarded]
      assert operation.last_failure_id == cause.id
    else
      assert ctx.retry.operation == nil
    end

    assert {:ok, stored_prior} = Agents.get_run(ctx.prior.id, actor: ctx.admin)
    assert stored_prior.status == ctx.prior.status
  end
end

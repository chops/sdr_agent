defmodule SdrAgent.InboxRetryFixtures do
  @moduledoc """
  Synthetic C1-03 B fixtures through actual assignment, reply and legacy
  retry domain APIs. Stamping a legacy retry is test setup for the new
  worker input contract, never an implementation of the C1 command.
  """

  import ExUnit.Assertions
  import SdrAgent.AuditCase, only: [events_of_type: 2]
  import SdrAgent.InboxFixtures, only: [item!: 2, refresh: 1, session!: 1]
  import SdrAgent.OutreachFixtures, only: [approved!: 2, deliver!: 0, outreach!: 2, put_env!: 2]
  import SdrAgent.SDRCase
  import SdrAgent.WebhookFixtures, only: [ingest!: 2, process!: 0, reply_body: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.Repo
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SDR.ReplyWorker

  defmodule InvalidQualification do
    @moduledoc false
    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule InvalidClassification do
    @moduledoc false
    def respond("sdr.reply_classification" = op, input),
      do: %{FakeBrain.respond(op, input) | confidence: 7}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  @doc "A real failed assignment/reply with known terminal generation-2 Fake calls."
  def prior!(ctx, :assignment) do
    %{run: run} =
      assign!(ctx, "01", model: [provider_options: [responder: InvalidQualification]])

    assert %{success: 1} = drain!()
    known_fake!(ctx, run)
  end

  def prior!(ctx, :reply) do
    approved = approved!(ctx, "01")
    assert %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)
    put_env!(:fake_model_responder, InvalidClassification)

    assert {:ok, %{status: :accepted}} =
             ingest!("reply", reply_body(delivery, "Synthetic reply: please tell me more."))

    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)
    put_env!(:fake_model_responder, FakeBrain)

    assert {:ok, runs} = Agents.list_runs(actor: ctx.admin)
    assert [run] = Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received"))
    known_fake!(ctx, run)
  end

  defp known_fake!(ctx, run) do
    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :invalid_model_output}
    invocations = invocations!(ctx, run)
    assert [_ | _] = invocations
    assert Enum.all?(invocations, &(&1.provider == :fake and &1.ledger_generation == 2))
    assert Enum.all?(invocations, &(&1.status in [:completed, :failed]))

    assert {:ok, %{status: :open}} =
             Operations.get_failure(run.attention_failure_id, actor: ctx.admin)

    run
  end

  @doc "The exact Failure row shown by the existing v1 projection."
  def displayed_retry!(ctx, prior, session \\ nil) do
    session = session || session!(ctx.admin)
    assert {:ok, failure} = Operations.get_failure(prior.attention_failure_id, actor: ctx.admin)
    assert {:ok, page} = refresh(session)
    row = item!(page, failure)

    request = %{
      action_id: :retry_run,
      source_id: failure.id,
      item_id: row.id,
      expected_freshness_token: row.freshness_token,
      args: %{confirm: true}
    }

    %{session: session, request: request, row: row, failure: failure}
  end

  @doc "Exercise the fixed gateway; no permissive retry helper is substituted."
  def command(session, request), do: SdrAgent.Inbox.command(session, request)

  @doc "Assert the new fixed source API before invoking it, after fixture setup."
  def source_command(session, request) do
    assert Code.ensure_loaded?(SDR) and function_exported?(SDR, :inbox_retry, 2),
           "C1-03 B source-owned inbox_retry/2 is not implemented"

    apply(SDR, :inbox_retry, [session, request])
  end

  @doc "The fixed metadata-only preview boundary; no domain substitute in RED."
  def preview(session, ids) do
    assert Code.ensure_loaded?(SDR) and function_exported?(SDR, :preview_inbox_retries, 2),
           "C1-03 B bounded preview_inbox_retries/2 is not implemented"

    apply(SDR, :preview_inbox_retries, [session, ids])
  end

  @doc "Find the one durable child, not a run id returned by a gateway."
  def child!(ctx, prior) do
    assert {:ok, runs} = Agents.list_runs(actor: ctx.admin)
    assert [child] = Enum.filter(runs, &(&1.retry_of_id == prior.id))
    child
  end

  @doc "Build the exact source-owned refuse-only marker."
  def binding(run, prior) do
    %{
      "version" => 1,
      "expected_provider" => "fake",
      "run_id" => run.id,
      "retry_of_id" => prior.id
    }
  end

  @doc "A source-created legacy retry, optionally stamped as a worker-input fixture."
  def queued_retry!(ctx, prior, marked? \\ true) do
    assert {:ok, retry} = SDR.retry_run(prior.id, actor: ctx.admin)

    job =
      if marked? do
        assert {:ok, job} =
                 Oban.update_job(retry.job, %{
                   args: Map.put(retry.job.args, "c1_retry_binding", binding(retry.run, prior))
                 })

        job
      else
        retry.job
      end

    Map.put(retry, :job, job)
  end

  @doc "Public worker paths, with raised/exit results converted to assertion data."
  def perform(job, entry \\ :perform) do
    case {job.worker, entry} do
      {"SdrAgent.SDR.AgentWorker", :perform} -> AgentWorker.perform(job)
      {"SdrAgent.SDR.AgentWorker", :run} -> AgentWorker.run(job, [])
      {"SdrAgent.SDR.ReplyWorker", :perform} -> ReplyWorker.perform(job)
    end
  rescue
    _ -> :raised_instead_of_typed_refusal
  catch
    _, _ -> :exited_instead_of_typed_refusal
  end

  @doc "A stored job of this run, through its actual Operation or reply run binding."
  def job!(ctx, run) do
    if run.operation_id do
      assert {:ok, operation} = Operations.get_operation(run.operation_id, actor: ctx.admin)
      assert %Oban.Job{} = job = Repo.get(Oban.Job, operation.oban_job_id)
      job
    else
      import Ecto.Query, only: [from: 2]

      assert [job] =
               Repo.all(
                 from(j in Oban.Job,
                   where:
                     j.worker == "SdrAgent.SDR.ReplyWorker" and
                       fragment("?->>'run_id' = ?", j.args, ^run.id)
                 )
               )

      job
    end
  end

  @doc "Durable refusal effects, excluding authorized denial audit records."
  def effects!(ctx) do
    assert {:ok, runs} = Agents.list_runs(actor: ctx.admin)

    assert {:ok, operations} =
             Ash.read(Operations.Operation, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))

    assert {:ok, failures} =
             Ash.read(Operations.Failure, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))

    %{
      runs: Enum.sort_by(runs, & &1.id),
      operations: Enum.sort_by(operations, & &1.id),
      failures: Enum.sort_by(failures, & &1.id),
      jobs: Repo.all(Oban.Job) |> Enum.sort_by(& &1.id),
      retried: events_of_type(ctx.tenant, "agents.run.retried")
    }
  end
end

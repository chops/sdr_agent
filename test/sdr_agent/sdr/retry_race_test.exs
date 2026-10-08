defmodule SdrAgent.SDR.RetryRaceTest do
  @moduledoc """
  Real connections (`sandbox: false`, as `SdrAgent.SDR.HandoffRaceTest`):
  two operators retry the same failed run at once. The locks (Lead → … →
  prior run `FOR UPDATE`) serialize them: exactly one new run, Operation and
  job; the other caller gets `:already_retried` (S13b soft-stop v3, A1).
  Likewise two webhook retries of one failed event: the event lock
  serializes them and the second sees the job queued (`:retry_pending`, B1).
  Committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Operations
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.FakeBrain

  @tables ~w(oban_jobs delivery_receipts delivery_operations send_quota_days approvals
             revision_citations draft_revisions drafts suppressions anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
             audit_accesses audit_events audit_chain_heads retention_markers
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions decisions tool_invocations model_invocations agent_runs
             failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  defmodule InvalidQualification do
    @moduledoc false
    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, _} = SdrAgent.Demo.Seed.run()
    {:ok, tenant_id} = Audit.Kernel.singleton_tenant_id()
    seeder = Actor.system(:seeder, tenant_id, "race")
    {:ok, admin} = Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)
    {:ok, lead} = Sales.fetch(Sales.Lead, hd(Fixtures.leads()).id, actor: admin)

    %{
      tenant_id: tenant_id,
      admin: admin,
      lead: lead,
      agent: Actor.system(:agent_runtime, tenant_id)
    }
  end

  test "two concurrent retries of one failed run: exactly one wins", ctx do
    {:ok, %{run: run, job: job}} =
      SDR.assign_lead(ctx.lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    # Jido runs Flow steps in Task processes: let them share this connection.
    Sandbox.mode(SdrAgent.Repo, {:shared, self()})
    AgentWorker.run(job, model: [provider_options: [responder: InvalidQualification]])
    # The original job ran inline, not through Oban: record it completed.
    SdrAgent.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    {:ok, failed} = Agents.get_run(run.id, actor: ctx.agent)
    assert failed.status == :failed

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          with_connection(fn -> SDR.retry_run(failed.id, actor: ctx.admin) end)
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :already_retried})) == 1, inspect(results)

    opts = Audit.Kernel.opts(ctx.tenant_id)
    {:ok, runs} = Ash.read(Agents.AgentRun, opts)
    assert Enum.count(runs, &(&1.retry_of_id == failed.id)) == 1
    {:ok, operations} = Ash.read(Operations.Operation, opts)
    assert Enum.count(operations, &(&1.idempotency_key == "retry:" <> failed.id)) == 1

    aud = Actor.system(:auditor_cli, ctx.tenant_id)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: aud)
  end

  test "two concurrent webhook retries of one failed event: exactly one wins", ctx do
    body = SdrAgent.WebhookFixtures.outcome_body("bounce", %{provider_message_id: "capture-0"})

    assert {:ok, %{status: :accepted, event: event}} =
             SdrAgent.WebhookFixtures.ingest!("bounce", body)

    assert %{success: 1} = SdrAgent.WebhookFixtures.process!()

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          with_connection(fn -> SdrAgent.Outreach.retry_webhook(event.id, actor: ctx.admin) end)
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, %{ordinal: 1}}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :retry_pending})) == 1, inspect(results)

    {:ok, events} = Ash.read(Audit.AuditEvent, Audit.Kernel.opts(ctx.tenant_id))
    assert Enum.count(events, &(&1.event_type == "webhook.retry_requested")) == 1
  end

  test "two concurrent failures of one retry request: exactly one consumes it", ctx do
    body = SdrAgent.WebhookFixtures.outcome_body("bounce", %{provider_message_id: "capture-0"})
    assert {:ok, %{event: event}} = SdrAgent.WebhookFixtures.ingest!("bounce", body)
    assert %{success: 1} = SdrAgent.WebhookFixtures.process!()
    assert {:ok, %{ordinal: 1}} = SdrAgent.Outreach.retry_webhook(event.id, actor: ctx.admin)
    whk = Actor.system(:webhook_ingestor, ctx.tenant_id)
    {:ok, failed} = Ash.get(SdrAgent.Operations.WebhookEvent, event.id, actor: whk)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          with_connection(fn ->
            failed
            |> Ash.Changeset.for_update(
              :record_retry_failed,
              %{class: :crash, reason: "concurrent failure"},
              actor: whk
            )
            |> Ash.update()
          end)
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &match?({:error, _}, &1)) == 1, inspect(results)

    {:ok, events} = Ash.read(Audit.AuditEvent, Audit.Kernel.opts(ctx.tenant_id))
    assert Enum.count(events, &(&1.event_type == "webhook.retry_failed")) == 1
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(SdrAgent.Repo)
    end
  end

  defp cleanup! do
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end

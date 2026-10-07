defmodule SdrAgent.Outreach.WebhookRaceTest do
  @moduledoc """
  Real connections (`sandbox: false`, as the S8b race suite) for the S9
  races: the same signed event delivered twice at once (one row, one job,
  one acknowledgement as duplicate), and a reply racing the delivery claim
  of the enrollment's next message (no deadlock; either the reply cancels
  the unsent delivery, or the delivery is in flight and completes without
  advancing a replied enrollment — never a second capture). Committed rows
  are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  import SdrAgent.WebhookFixtures, only: [reply_body: 2, signed_headers: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker

  @tables ~w(oban_jobs replies webhook_events delivery_receipts delivery_operations
             send_quota_days approvals revision_citations draft_revisions drafts suppressions
             anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
             audit_accesses audit_events audit_chain_heads retention_markers
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions decisions tool_invocations model_invocations agent_runs
             failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, _} = SdrAgent.Demo.Seed.run()
    {:ok, tenant_id} = Audit.Kernel.singleton_tenant_id()
    seeder = Actor.system(:seeder, tenant_id, "race")
    {:ok, admin} = SdrAgent.Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)
    %{tenant_id: tenant_id, admin: admin, agent: Actor.system(:agent_runtime, tenant_id)}
  end

  test "the same signed event twice at once: one row, one job, one duplicate", ctx do
    %{delivery: op} = delivered!(ctx)
    body = reply_body(op, "Interested!")
    headers = Map.new(signed_headers(body))

    results = race(for _ <- 1..2, do: fn -> Webhooks.ingest("reply", body, headers) end)

    statuses = Enum.map(results, fn {:ok, %{status: status}} -> status end)
    assert Enum.sort(statuses) == [:accepted, :duplicate]

    {:ok, events} = Ash.read(WebhookEvent, actor: ctx.admin)
    assert length(events) == 1

    {:ok, %{rows: [[jobs]]}} =
      SQL.query(SdrAgent.Repo, "SELECT count(*) FROM oban_jobs WHERE queue = 'integration'", [])

    assert jobs == 1
  end

  test "a reply racing the claim of the next delivery: no deadlock, one outcome", ctx do
    %{delivery: first} = drafted = delivered!(ctx)
    next = approved_followup!(ctx, drafted)
    body = reply_body(first, "Thanks, not now.")

    {:ok, %{status: :accepted, event: event}} =
      Webhooks.ingest("reply", body, Map.new(signed_headers(body)))

    [processed, attempted] =
      race([
        fn -> Webhooks.process(event.id, ctx.tenant_id, body) end,
        fn -> Delivery.attempt(next.id, ctx.tenant_id) end
      ])

    assert processed == :ok, inspect(processed)
    assert attempted == :ok, inspect(attempted)

    next = fetch!(ctx, Outreach.DeliveryOperation, next.id)
    enrollment = fetch_sales!(ctx, Sales.CampaignEnrollment, next.enrollment_id)

    case next.state do
      :cancelled -> assert enrollment.status == :replied
      :accepted -> assert enrollment.status in [:replied, :completed]
    end

    {:ok, receipts} =
      Outreach.list_records(Outreach.DeliveryReceipt,
        filter: [delivery_operation_id: next.id, kind: :captured],
        actor: ctx.admin
      )

    assert length(receipts) <= 1
    assert [_reply] = elem(Outreach.list_records(Outreach.Reply, actor: ctx.admin), 1)
  end

  test "a reply racing a manual suppression of the same contact: both finish, no deadlock",
       ctx do
    %{delivery: first} = drafted = delivered!(ctx)
    next = approved_followup!(ctx, drafted)
    body = reply_body(first, "Thanks, not now.")

    {:ok, %{status: :accepted, event: event}} =
      Webhooks.ingest("reply", body, Map.new(signed_headers(body)))

    [processed, suppressed] =
      race([
        fn -> Webhooks.process(event.id, ctx.tenant_id, body) end,
        fn ->
          Outreach.suppress(%{scope: :email, value: to_string(first.recipient_email)},
            actor: ctx.admin
          )
        end
      ])

    assert processed == :ok, inspect(processed)
    assert {:ok, _} = suppressed
    refute inspect(suppressed) =~ "deadlock"

    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    assert event.processing_status == :processed
    assert fetch!(ctx, Outreach.DeliveryOperation, next.id).state == :cancelled
    lead = fetch_sales!(ctx, Sales.Lead, Enum.at(Fixtures.leads(), 0).id)
    assert lead.status == :stopped
    assert [_reply] = elem(Outreach.list_records(Outreach.Reply, actor: ctx.admin), 1)
  end

  test "one Message-ID under two event ids at once: one reply, both events processed", ctx do
    %{delivery: op} = delivered!(ctx)
    msg = "<same-message@prospect.example.test>"

    events =
      for id <- ["evt_msg_a", "evt_msg_b"] do
        body =
          op
          |> SdrAgent.WebhookFixtures.reply_body("Interested!", id: id)
          |> Jason.decode!()
          |> put_in(["data", "message_id"], msg)
          |> Jason.encode!()

        {:ok, %{status: :accepted, event: event}} =
          Webhooks.ingest("reply", body, Map.new(signed_headers(body)))

        {event, body}
      end

    results =
      race(for {e, body} <- events, do: fn -> Webhooks.process(e.id, ctx.tenant_id, body) end)

    assert Enum.all?(results, &(&1 == :ok)), inspect(results)

    {:ok, stored} = Ash.read(WebhookEvent, actor: ctx.admin)
    assert Enum.map(stored, & &1.processing_status) == [:processed, :processed]
    assert [_reply] = elem(Outreach.list_records(Outreach.Reply, actor: ctx.admin), 1)
  end

  # Lead "01" worked by the agent, approved by the admin, delivered.
  defp delivered!(ctx) do
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), 0).id, actor: ctx.admin)

    {:ok, %{job: job}} =
      SDR.assign_lead(lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    :ok =
      Task.async(fn ->
        with_connection(fn ->
          Sandbox.mode(SdrAgent.Repo, {:shared, self()})
          AgentWorker.run(job, model: [])
        end)
      end)
      |> Task.await(60_000)

    _ = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    revision = fetch!(ctx, Outreach.DraftRevision, draft.current_revision_id)
    {:ok, approval} = Outreach.approve(draft, approval_binding(revision), actor: ctx.admin)
    op = delivery_of!(ctx, approval)
    :ok = Delivery.attempt(op.id, ctx.tenant_id)

    %{draft: draft, revision: revision, delivery: fetch!(ctx, Outreach.DeliveryOperation, op.id)}
  end

  defp approved_followup!(ctx, drafted) do
    followup =
      SdrAgent.WebhookFixtures.followup_draft!(%{admin: ctx.admin, agent: ctx.agent}, drafted)

    revision = fetch!(ctx, Outreach.DraftRevision, followup.current_revision_id)
    {:ok, approval} = Outreach.approve(followup, approval_binding(revision), actor: ctx.admin)
    delivery_of!(ctx, approval)
  end

  # The reviewed binding, including the recipient email a reviewer sees (#17 MF1).
  defp approval_binding(revision), do: SdrAgent.OutreachFixtures.approval_input(revision)

  defp delivery_of!(ctx, approval) do
    {:ok, [op]} =
      Outreach.list_records(Outreach.DeliveryOperation,
        filter: [approval_id: approval.id],
        actor: ctx.admin
      )

    op
  end

  defp fetch!(ctx, resource, id) do
    {:ok, record} = Outreach.fetch(resource, id, actor: ctx.admin)
    record
  end

  defp fetch_sales!(ctx, resource, id) do
    {:ok, record} = Sales.fetch(resource, id, actor: ctx.admin)
    record
  end

  # Runs every function in its own connection, released together.
  defp race(funs) do
    parent = self()
    tasks = Enum.map(funs, &Task.async(fn -> gated(parent, &1) end))
    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 60_000)
  end

  defp gated(parent, fun) do
    with_connection(fn ->
      send(parent, {:ready, self()})
      receive do: (:go -> :ok)
      fun.()
    end)
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

defmodule SdrAgent.Outreach.DeliveryRaceTest do
  @moduledoc """
  Real connections (`sandbox: false`, as S3's and S7's concurrency suites)
  for the S8b transitions that race (ADR-0010): two workers claiming one
  delivery, a revoke against a claim, and two deliveries competing for the
  last unit of the daily cap. In each, exactly one side wins and nothing is
  captured twice. Committed rows are removed afterwards with triggers
  disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker

  @tables ~w(oban_jobs delivery_receipts delivery_operations send_quota_days approvals
             revision_citations draft_revisions drafts suppressions
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
    seeder = SdrAgent.Actor.system(:seeder, tenant_id, "race")
    {:ok, admin} = SdrAgent.Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)
    %{tenant_id: tenant_id, admin: admin}
  end

  test "two workers claiming one delivery: one claim, one capture", ctx do
    %{delivery: op} = approved!(ctx, 0)

    results = race([fn -> Delivery.attempt(op.id, ctx.tenant_id) end, fn -> Delivery.attempt(op.id, ctx.tenant_id) end])
    assert Enum.all?(results, &(&1 == :ok)), inspect(results)

    op = reload!(ctx, op)
    assert {op.state, op.attempt_count} == {:accepted, 1}
    assert [:captured, :accepted] = kinds(ctx, op)
    assert passes(ctx, op) == 1
  end

  test "a revoke racing a claim: exactly one wins", ctx do
    %{delivery: op, approval: approval} = approved!(ctx, 0)

    [revoke, attempt] =
      race([
        fn -> Outreach.revoke(approval, actor: ctx.admin) end,
        fn -> Delivery.attempt(op.id, ctx.tenant_id) end
      ])

    assert attempt == :ok
    op = reload!(ctx, op)
    {:ok, approval} = Outreach.fetch(Outreach.Approval, approval.id, actor: ctx.admin)

    case revoke do
      {:ok, _} ->
        assert {approval.status, op.state, kinds(ctx, op)} == {:revoked, :cancelled, []}

      {:error, _} ->
        assert {approval.status, op.state} == {:consumed, :accepted}
        assert [:captured, :accepted] = kinds(ctx, op)
    end
  end

  test "two deliveries for the last unit of the cap: one is sent, one waits", ctx do
    Application.put_env(:sdr_agent, :daily_send_cap, 1)
    on_exit(fn -> Application.delete_env(:sdr_agent, :daily_send_cap) end)
    %{delivery: first} = approved!(ctx, 0)
    %{delivery: second} = approved!(ctx, 1)

    results = race(for op <- [first, second], do: fn -> Delivery.attempt(op.id, ctx.tenant_id) end)
    assert Enum.all?(results, &(&1 == :ok)), inspect(results)

    states = Enum.map([first, second], &reload!(ctx, &1).state) |> Enum.sort()
    assert states == [:accepted, :pending]
    {:ok, [day]} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)
    assert {day.cap, day.consumed} == {1, 1}
  end

  # A qualified fixture lead (by index in Fixtures.leads/0), worked by the
  # agent and approved by the admin.
  defp approved!(ctx, index) do
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), index).id, actor: ctx.admin)
    {:ok, %{job: job}} = SDR.assign_lead(lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    :ok =
      Task.async(fn ->
        with_connection(fn ->
          Sandbox.mode(SdrAgent.Repo, {:shared, self()})
          AgentWorker.run(job, model: [])
        end)
      end)
      |> Task.await(60_000)

    _ = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    {:ok, [draft]} = Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)
    {:ok, revision} = Outreach.fetch(Outreach.DraftRevision, draft.current_revision_id, actor: ctx.admin)

    {:ok, approval} =
      Outreach.approve(
        draft,
        %{draft_revision_id: revision.id, content_sha256: Base.encode16(revision.content_sha256, case: :lower)},
        actor: ctx.admin
      )

    {:ok, [op]} =
      Outreach.list_records(Outreach.DeliveryOperation, filter: [approval_id: approval.id], actor: ctx.admin)

    %{delivery: op, approval: approval}
  end

  # Runs every function in its own connection, released together.
  defp race(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          with_connection(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            fun.()
          end)
        end)
      end)

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 60_000)
  end

  defp reload!(ctx, op) do
    {:ok, op} = Outreach.fetch(Outreach.DeliveryOperation, op.id, actor: ctx.admin)
    op
  end

  defp kinds(ctx, op) do
    {:ok, receipts} =
      Outreach.list_records(Outreach.DeliveryReceipt, filter: [delivery_operation_id: op.id], actor: ctx.admin)

    Enum.map(receipts, & &1.kind)
  end

  defp passes(ctx, op) do
    {:ok, decisions} = Ash.read(SdrAgent.Agents.Decision, actor: ctx.admin)
    Enum.count(decisions, &(&1.subject_id == op.id and &1.kind == :send_gate and &1.outcome == "pass"))
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

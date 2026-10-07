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

    results =
      race([
        fn -> Delivery.attempt(op.id, ctx.tenant_id) end,
        fn -> Delivery.attempt(op.id, ctx.tenant_id) end
      ])

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

  test "a suppression racing a revoke of the same draft: both finish, no deadlock", ctx do
    %{delivery: op, approval: approval} = approved!(ctx, 0)
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), 0).id, actor: ctx.admin)
    {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: ctx.admin)

    [revoke, suppress] =
      race([
        fn -> Outreach.revoke(approval, actor: ctx.admin) end,
        fn ->
          Outreach.suppress(%{scope: :email, value: to_string(contact.email)}, actor: ctx.admin)
        end
      ])

    assert {:ok, _} = suppress

    assert match?({:ok, _}, revoke) or match?({:error, %Ash.Error.Invalid{}}, revoke),
           inspect(revoke)

    refute inspect(revoke) =~ "deadlock"

    assert reload!(ctx, op).state == :cancelled
    {:ok, draft} = Outreach.fetch(Outreach.Draft, op.draft_id, actor: ctx.admin)
    assert draft.status == :cancelled
    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    assert lead.status == :stopped
  end

  test "two deliveries for the last unit of the cap: one is sent, one waits", ctx do
    Application.put_env(:sdr_agent, :daily_send_cap, 1)
    on_exit(fn -> Application.delete_env(:sdr_agent, :daily_send_cap) end)
    %{delivery: first} = approved!(ctx, 0)
    %{delivery: second} = approved!(ctx, 1)

    results =
      race(for op <- [first, second], do: fn -> Delivery.attempt(op.id, ctx.tenant_id) end)

    assert Enum.all?(results, &(&1 == :ok)), inspect(results)

    states = Enum.map([first, second], &reload!(ctx, &1).state) |> Enum.sort()
    assert states == [:accepted, :pending]
    {:ok, [day]} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)
    assert {day.cap, day.consumed} == {1, 1}
  end

  # Review #14 MF1: a writer that locks the enrollment, then the draft (the
  # suppression order) must not deadlock with a grant.
  test "a grant against a writer holding enrollment then draft: no deadlock, atomic outbox",
       ctx do
    %{draft: draft, revision: revision} = drafted_rt!(ctx, 0)
    parent = self()

    writer =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn ->
            {:ok, _} = lock_row(ctx, Sales.CampaignEnrollment, draft.enrollment_id)
            send(parent, :enrollment_locked)
            receive do: (:next -> :ok)
            {:ok, _} = lock_row(ctx, Outreach.Draft, draft.id)
            :ok
          end)
        end)
      end)

    assert_receive :enrollment_locked, 10_000

    granter =
      Task.async(fn ->
        with_connection(fn ->
          Outreach.approve(draft, approval_input(revision), actor: ctx.admin)
        end)
      end)

    Process.sleep(1_000)
    send(writer.pid, :next)

    assert {:ok, :ok} = Task.await(writer, 60_000)
    assert {:ok, approval} = Task.await(granter, 60_000)

    assert {:ok, [op]} =
             Outreach.list_records(Outreach.DeliveryOperation,
               filter: [approval_id: approval.id],
               actor: ctx.admin
             )

    assert op.state == :pending
  end

  test "a grant racing a suppression: no deadlock, no granted approval left behind", ctx do
    %{draft: draft, revision: revision, lead: lead} = drafted_rt!(ctx, 0)
    {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: ctx.admin)

    [grant, suppress] =
      race([
        fn -> Outreach.approve(draft, approval_input(revision), actor: ctx.admin) end,
        fn ->
          Outreach.suppress(%{scope: :email, value: to_string(contact.email)}, actor: ctx.admin)
        end
      ])

    assert {:ok, _} = suppress

    assert match?({:ok, _}, grant) or match?({:error, %Ash.Error.Invalid{}}, grant),
           inspect(grant)

    {:ok, approvals} =
      Outreach.list_records(Outreach.Approval, filter: [draft_id: draft.id], actor: ctx.admin)

    assert Enum.all?(approvals, &(&1.status == :invalidated))

    {:ok, ops} =
      Outreach.list_records(Outreach.DeliveryOperation,
        filter: [draft_id: draft.id],
        actor: ctx.admin
      )

    assert Enum.all?(ops, &(&1.state == :cancelled))
  end

  # Review #14 MF2: a change that commits while the gate evaluates must be
  # seen by it: no claim, capture, consumed approval or quota unit.
  for {label, mutate} <- [
        {"a recipient email change",
         quote do
           fn ctx, op ->
             {:ok, contact} =
               Sales.fetch(Sales.Contact, op.recipient_contact_id, actor: ctx.admin)

             Sales.update(contact, :change_email, %{email: "moved.away@brightpath-freight.test"},
               actor: ctx.admin
             )
           end
         end},
        {"a campaign pause",
         quote do
           fn ctx, op ->
             {:ok, campaign} = Sales.fetch(Sales.Campaign, op.campaign_id, actor: ctx.admin)
             Sales.update(campaign, :pause, %{}, actor: ctx.admin)
           end
         end},
        {"an enrollment stop",
         quote do
           fn ctx, op ->
             {:ok, enrollment} =
               Sales.fetch(Sales.CampaignEnrollment, op.enrollment_id, actor: ctx.admin)

             Sales.update(enrollment, :stop, %{stop_reason: :manual}, actor: ctx.admin)
           end
         end}
      ] do
    test "#{label} committed while the gate runs is seen: no claim, no capture", ctx do
      %{delivery: op, approval: approval} = approved!(ctx, 0)
      parent = self()
      mutate = unquote(mutate)

      mutation =
        Task.async(fn ->
          with_connection(fn ->
            Audit.transaction(fn ->
              {:ok, _} = mutate.(ctx, op)
              send(parent, :mutated)
              receive do: (:commit -> :ok)
            end)
          end)
        end)

      assert_receive :mutated, 10_000

      attempt =
        Task.async(fn -> with_connection(fn -> Delivery.attempt(op.id, ctx.tenant_id) end) end)

      Process.sleep(1_000)
      send(mutation.pid, :commit)
      assert {:ok, :ok} = Task.await(mutation, 60_000)
      assert :ok = Task.await(attempt, 60_000)

      op = reload!(ctx, op)
      assert op.state == :cancelled, inspect({op.state, op.last_error})
      assert kinds(ctx, op) == []
      {:ok, approval} = Outreach.fetch(Outreach.Approval, approval.id, actor: ctx.admin)
      refute approval.status == :consumed
      {:ok, days} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)
      assert Enum.all?(days, &(&1.consumed == 0))
    end
  end

  # Review #14 MF3: concurrent executions of one follow-up publish once.
  test "two concurrent follow-up executions: one decision, one sdr.followup.due", ctx do
    %{delivery: op} = approved!(ctx, 0)
    :ok = Delivery.attempt(op.id, ctx.tenant_id)
    {:ok, enrollment} = Sales.fetch(Sales.CampaignEnrollment, op.enrollment_id, actor: ctx.admin)
    Clock.freeze(enrollment.next_step_due_at)

    job = %Oban.Job{
      args: %{
        "enrollment_id" => enrollment.id,
        "tenant_id" => ctx.tenant_id,
        "step_position" => 1
      }
    }

    results = race(for _ <- 1..2, do: fn -> SdrAgent.SDR.FollowupWorker.perform(job) end)
    assert Enum.all?(results, &(&1 == :ok)), inspect(results)

    {:ok, decisions} = Ash.read(SdrAgent.Agents.Decision, actor: ctx.admin)

    assert Enum.count(
             decisions,
             &(&1.subject_id == enrollment.id and &1.kind == :followup_next_step)
           ) == 1

    {:ok, events} = Audit.list_events(actor: SdrAgent.Actor.system(:auditor_cli, ctx.tenant_id))
    assert Enum.count(events, &(&1.event_type == "sdr.followup.due")) == 1
  end

  # A qualified fixture lead (by index in Fixtures.leads/0), worked by the
  # agent and approved by the admin.
  defp approved!(ctx, index) do
    %{draft: draft, revision: revision} = drafted_rt!(ctx, index)
    {:ok, approval} = Outreach.approve(draft, approval_input(revision), actor: ctx.admin)

    {:ok, [op]} =
      Outreach.list_records(Outreach.DeliveryOperation,
        filter: [approval_id: approval.id],
        actor: ctx.admin
      )

    %{delivery: op, approval: approval}
  end

  # A qualified fixture lead worked by the agent: its draft and revision.
  defp drafted_rt!(ctx, index) do
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), index).id, actor: ctx.admin)

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

    {:ok, revision} =
      Outreach.fetch(Outreach.DraftRevision, draft.current_revision_id, actor: ctx.admin)

    %{draft: draft, revision: revision, lead: lead}
  end

  defp approval_input(revision),
    do: %{
      draft_revision_id: revision.id,
      content_sha256: Base.encode16(revision.content_sha256, case: :lower)
    }

  defp lock_row(ctx, resource, id) do
    require Ash.Query

    resource
    |> Ash.Query.for_read(:read, %{}, actor: ctx.admin)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
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

  defp reload!(ctx, op) do
    {:ok, op} = Outreach.fetch(Outreach.DeliveryOperation, op.id, actor: ctx.admin)
    op
  end

  defp kinds(ctx, op) do
    {:ok, receipts} =
      Outreach.list_records(Outreach.DeliveryReceipt,
        filter: [delivery_operation_id: op.id],
        actor: ctx.admin
      )

    Enum.map(receipts, & &1.kind)
  end

  defp passes(ctx, op) do
    {:ok, decisions} = Ash.read(SdrAgent.Agents.Decision, actor: ctx.admin)

    Enum.count(
      decisions,
      &(&1.subject_id == op.id and &1.kind == :send_gate and &1.outcome == "pass")
    )
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

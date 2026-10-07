defmodule SdrAgent.Outreach.OutreachRaceTest do
  @moduledoc """
  Real connections (`sandbox: false`) for the S8a review findings:

    * #13 MF2 — a Contact writer holding the contact row while the agent's
      hand-off (which now creates a Draft referencing that contact) runs:
      both finish serially, without a deadlock, and the hand-off stays
      atomic (enrollment, Draft and hand-off record together);
    * #13 MF1 — an operator stopping a lead while its contact is suppressed:
      whichever commits first, the enrollment, draft and approval end up
      stopped, cancelled and invalidated.

  Committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.FakeBrain

  @tables ~w(oban_jobs approvals revision_citations draft_revisions drafts suppressions
             anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
             audit_accesses audit_events audit_chain_heads retention_markers
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions decisions tool_invocations model_invocations agent_runs
             failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  defmodule PausingResponder do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      send(:persistent_term.get({__MODULE__, :test}), {:drafting, self()})
      receive do: (:go -> :ok)
      FakeBrain.respond(op, input)
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))

    on_exit(fn ->
      with_connection(&cleanup!/0)
      :persistent_term.erase({PausingResponder, :test})
    end)

    {:ok, _} = SdrAgent.Demo.Seed.run()
    {:ok, tenant_id} = Audit.Kernel.singleton_tenant_id()
    seeder = SdrAgent.Actor.system(:seeder, tenant_id, "race")
    {:ok, admin} = SdrAgent.Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)
    {:ok, lead} = Sales.fetch(Sales.Lead, hd(Fixtures.leads()).id, actor: admin)
    {:ok, contact} = Sales.fetch(Sales.Contact, lead.contact_id, actor: admin)
    %{tenant_id: tenant_id, admin: admin, lead: lead, contact: contact}
  end

  test "a Contact writer holding the row while the hand-off creates its Draft: no deadlock",
       ctx do
    :persistent_term.put({PausingResponder, :test}, self())
    {:ok, %{run: run, job: job}} = assign(ctx)

    agent =
      Task.async(fn ->
        with_connection(fn ->
          Sandbox.mode(SdrAgent.Repo, {:shared, self()})
          AgentWorker.run(job, model: [provider_options: [responder: PausingResponder]])
        end)
      end)

    responder = receive(do: ({:drafting, pid} -> pid), after: (90_000 -> flunk("no draft step")))
    parent = self()

    # The operator locks the contact first (as Contact.change_email does),
    # lets the agent run into its hand-off, then changes the email.
    operator =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn ->
            {:ok, locked} = lock_contact(ctx)
            send(parent, :contact_locked)
            receive do: (:change -> :ok)

            Sales.update(locked, :change_email, %{email: "avery.new@brightpath-freight.test"},
              actor: ctx.admin
            )
          end)
        end)
      end)

    assert_receive :contact_locked, 10_000
    send(responder, :go)
    Process.sleep(1_500)
    send(operator.pid, :change)

    assert {:ok, {:ok, _contact}} = Task.await(operator, 60_000)
    assert :ok = Task.await(agent, 60_000)
    _ = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    {:ok, run} =
      Agents.get_run(run.id, actor: SdrAgent.Actor.system(:agent_runtime, ctx.tenant_id))

    assert run.status == :succeeded, inspect({run.status, run.failure_reason})

    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: ctx.lead.id], actor: ctx.admin)

    {:ok, enrollments} =
      Sales.list_records(Sales.CampaignEnrollment,
        filter: [lead_id: ctx.lead.id],
        actor: ctx.admin
      )

    assert {length(drafts), length(enrollments)} == {1, 1}

    assert {:ok, %{valid?: true}} =
             Audit.verify_chain(actor: SdrAgent.Actor.system(:auditor_cli, ctx.tenant_id))
  end

  test "an operator stop racing a suppression: the dependent work always ends", ctx do
    {:ok, %{job: job}} = assign(ctx)
    :ok = run_agent(job)

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: ctx.lead.id], actor: ctx.admin)

    {:ok, revision} =
      Outreach.fetch(Outreach.DraftRevision, draft.current_revision_id, actor: ctx.admin)

    {:ok, approval} = Outreach.approve(draft, approval_input(revision), actor: ctx.admin)
    {:ok, lead} = Sales.fetch(Sales.Lead, ctx.lead.id, actor: ctx.admin)

    [stop, suppress] =
      race([
        fn -> Sales.update(lead, :stop, %{status_reason: "operator stop"}, actor: ctx.admin) end,
        fn ->
          Outreach.suppress(%{scope: :email, value: to_string(ctx.contact.email)},
            actor: ctx.admin
          )
        end
      ])

    assert {:ok, _} = suppress
    assert match?({:ok, _}, stop) or match?({:error, %Ash.Error.Invalid{}}, stop), inspect(stop)

    {:ok, [enrollment]} =
      Sales.list_records(Sales.CampaignEnrollment,
        filter: [lead_id: ctx.lead.id],
        actor: ctx.admin
      )

    {:ok, draft} = Outreach.fetch(Outreach.Draft, draft.id, actor: ctx.admin)
    {:ok, approval} = Outreach.fetch(Outreach.Approval, approval.id, actor: ctx.admin)
    {:ok, lead} = Sales.fetch(Sales.Lead, ctx.lead.id, actor: ctx.admin)

    assert {lead.status, enrollment.status, draft.status, approval.status} ==
             {:stopped, :stopped, :cancelled, :invalidated}
  end

  defp assign(ctx),
    do: SDR.assign_lead(ctx.lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

  defp run_agent(job) do
    result =
      Task.async(fn ->
        with_connection(fn ->
          Sandbox.mode(SdrAgent.Repo, {:shared, self()})
          AgentWorker.run(job, model: [])
        end)
      end)
      |> Task.await(60_000)

    _ = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    result
  end

  defp lock_contact(ctx) do
    require Ash.Query

    Sales.Contact
    |> Ash.Query.for_read(:read, %{}, actor: ctx.admin)
    |> Ash.Query.filter(id == ^ctx.contact.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  defp approval_input(revision), do: SdrAgent.OutreachFixtures.approval_input(revision)

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

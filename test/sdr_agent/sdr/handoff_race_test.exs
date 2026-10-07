defmodule SdrAgent.SDR.HandoffRaceTest do
  @moduledoc """
  Real connections (`sandbox: false`, as S3's concurrency suite): an
  operator stops the lead in another transaction while the agent is
  preparing its proposal, and commits while the agent is mid-flow. The
  hand-off must then refuse — no enrollment, no `sdr.draft.completed`, a
  `refused` enrollment Decision and a stopped lead — and the run ends
  normally. A second test races two assignments of one lead: exactly one
  wins. Committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.FakeBrain

  @tables ~w(oban_jobs anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
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

    %{
      tenant_id: tenant_id,
      admin: admin,
      lead: lead,
      agent: SdrAgent.Actor.system(:agent_runtime, tenant_id)
    }
  end

  test "a lead stopped while the proposal is prepared is never handed off", ctx do
    :persistent_term.put({PausingResponder, :test}, self())

    {:ok, %{run: run, job: job}} =
      SDR.assign_lead(ctx.lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    agent =
      Task.async(fn ->
        with_connection(fn ->
          # Jido runs Flow steps in Task processes: let them share this
          # (non-sandboxed) connection; the operator task checks out its own.
          Sandbox.mode(SdrAgent.Repo, {:shared, self()})
          AgentWorker.run(job, model: [provider_options: [responder: PausingResponder]])
        end)
      end)

    responder =
      receive do
        {:drafting, pid} ->
          pid

        {ref, result} when ref == agent.ref ->
          {:ok, decisions} = Agents.list_decisions(run.id, actor: ctx.agent)
          {:ok, done} = Agents.get_run(run.id, actor: ctx.agent)

          flunk(
            "agent ended before drafting: #{inspect(result)} " <>
              inspect(
                {done.status, done.phase, done.failure_reason,
                 Enum.map(decisions, &{&1.kind, &1.outcome})}
              )
          )
      after
        90_000 -> flunk("the agent never reached the draft")
      end

    parent = self()

    operator =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn ->
            {:ok, lead} = Sales.fetch(Sales.Lead, ctx.lead.id, actor: ctx.admin)

            {:ok, _} =
              Sales.update(lead, :stop, %{status_reason: "operator stop"}, actor: ctx.admin)

            send(parent, :stopped_uncommitted)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :stopped_uncommitted, 10_000
    send(responder, :go)
    Process.sleep(500)
    send(operator.pid, :commit)
    assert {:ok, _} = Task.await(operator, 30_000)
    assert :ok = Task.await(agent, 60_000)
    # Shared mode ended with the agent's connection; check this process back out.
    _ = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    {:ok, run} = Agents.get_run(run.id, actor: ctx.agent)
    assert run.status == :succeeded
    assert run.phase == :stop

    {:ok, decisions} = Agents.list_decisions(run.id, actor: ctx.agent)
    assert [%{outcome: "refused"}] = Enum.filter(decisions, &(&1.kind == :enrollment))

    {:ok, enrollments} =
      Sales.list_records(Sales.CampaignEnrollment,
        filter: [lead_id: ctx.lead.id],
        actor: ctx.admin
      )

    assert enrollments == []
    {:ok, lead} = Sales.fetch(Sales.Lead, ctx.lead.id, actor: ctx.admin)
    assert lead.status == :stopped
    assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)
    aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant_id)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: aud)
  end

  test "two concurrent assignments of one lead: exactly one wins", ctx do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          with_connection(fn ->
            SDR.assign_lead(ctx.lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)
          end)
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :assignment_active})) == 1, inspect(results)

    {:ok, runs} = Ash.read(Agents.AgentRun, Audit.Kernel.opts(ctx.tenant_id))
    assert length(runs) == 1
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

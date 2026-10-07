defmodule SdrAgent.SDRCase do
  @moduledoc """
  Test case for the SDR agent plane (S7b): seeds the deterministic demo
  data set with the clock frozen one day after the fixture epoch, and offers
  helpers to assign a lead and run its Oban job inline.
  """
  use ExUnit.CaseTemplate

  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed

  using do
    quote do
      use Oban.Testing, repo: SdrAgent.Repo
      import SdrAgent.AuditCase
      import SdrAgent.SDRCase
      alias SdrAgent.Repo
    end
  end

  setup tags do
    SdrAgent.DataCase.setup_sandbox(tags)
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(&Clock.unfreeze/0)
    {:ok, _counts} = Seed.run()
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()

    {:ok, tenant} =
      Ash.get(SdrAgent.Audit.Tenant, tenant_id, SdrAgent.Audit.Kernel.opts(tenant_id))

    seeder = Actor.system(:seeder, tenant.id, "test")
    [admin | _] = Fixtures.users()
    {:ok, admin} = Accounts.get_user(admin.id, actor: seeder)

    %{
      tenant: tenant,
      admin: admin,
      agent: Actor.system(:agent_runtime, tenant.id),
      aud: Actor.system(:auditor_cli, tenant.id),
      campaign_id: Fixtures.campaign().id
    }
  end

  @doc "The seeded lead of company fixture `key` (\"01\"…\"10\")."
  def fixture_lead!(ctx, key) do
    index = String.to_integer(key) - 1
    lead = Enum.at(Fixtures.leads(), index)
    {:ok, lead} = SdrAgent.Sales.fetch(SdrAgent.Sales.Lead, lead.id, actor: ctx.admin)
    lead
  end

  @doc "Assigns the fixture lead `key` to the agent as ADM; returns the assignment."
  def assign!(ctx, key, opts \\ []) do
    lead = fixture_lead!(ctx, key)

    {:ok, assignment} =
      SdrAgent.SDR.assign_lead(
        lead,
        Keyword.merge([campaign_id: ctx.campaign_id, actor: ctx.admin], opts)
      )

    assignment
  end

  @doc "Runs every queued research job inline (Oban testing: manual)."
  def drain! do
    Oban.drain_queue(queue: :research, with_safety: false)
  end

  @doc "Reloads an agent run as the agent runtime."
  def run!(ctx, run) do
    {:ok, run} = SdrAgent.Agents.get_run(run.id, actor: ctx.agent)
    run
  end

  @doc "Decisions of a run, oldest first."
  def decisions!(ctx, run) do
    {:ok, decisions} = SdrAgent.Agents.list_decisions(run.id, actor: ctx.agent)
    decisions
  end

  @doc "Model invocations of a run, in call order."
  def invocations!(ctx, run) do
    {:ok, invocations} = SdrAgent.Agents.list_model_invocations(run.id, actor: ctx.agent)
    invocations
  end

  @doc "Signal events of a run, in ledger order."
  def signal_types(tenant, run) do
    tenant
    |> SdrAgent.AuditCase.events()
    |> Enum.filter(&(&1.category == :signal and &1.agent_run_id == run.id))
    |> Enum.map(& &1.event_type)
  end
end

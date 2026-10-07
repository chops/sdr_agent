defmodule SdrAgent.SDR.AssignmentTest do
  @moduledoc """
  S7b review (Codex, PR #12) must-fix 1 and the active-assignment item:
  `SDR.assign_lead/2` authorizes the caller (ADM/REV of the lead's tenant)
  at the public boundary for new *and* already-assigned leads, audits an
  auditor's attempt, works from the authoritative locked Lead row (not the
  caller's struct), and refuses to duplicate an active assignment. A refused
  call writes nothing.
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker

  defp counts(ctx) do
    opts = Kernel.opts(ctx.tenant.id)
    {:ok, runs} = Ash.read(AgentRun, opts)
    {:ok, operations} = Ash.read(Operation, opts)

    %{
      runs: length(runs),
      operations: length(operations),
      jobs: length(all_enqueued(worker: AgentWorker)),
      signals: length(events_of_type(ctx.tenant, "sdr.lead.assigned"))
    }
  end

  defp assigned_without_run!(ctx, key) do
    {:ok, lead} = Sales.update(fixture_lead!(ctx, key), :assign, %{}, actor: ctx.admin)
    lead
  end

  defp assign(lead, ctx, actor),
    do: SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: actor)

  test "ADM and REV assign new and already-assigned leads", ctx do
    reviewer = human(:reviewer, ctx.tenant)

    assert {:ok, %{run: run}} = assign(fixture_lead!(ctx, "01"), ctx, ctx.admin)
    assert run.lead_id == fixture_lead!(ctx, "01").id

    assigned = assigned_without_run!(ctx, "02")
    assert {:ok, %{lead: lead, run: run}} = assign(assigned, ctx, reviewer)
    assert lead.status == :assigned
    assert run.status == :queued
  end

  test "unauthorized callers are refused for both lead states and nothing is written", ctx do
    auditor = human(:auditor, ctx.tenant)
    foreign_admin = %{ctx.admin | tenant_id: Ecto.UUID.generate()}
    new_lead = fixture_lead!(ctx, "01")
    assigned = assigned_without_run!(ctx, "02")
    before = counts(ctx)
    denials = length(events_of_type(ctx.tenant, "authz.denied"))

    for lead <- [new_lead, assigned],
        actor <- [nil, ctx.agent, ctx.aud, foreign_admin] do
      assert {:error, %Ash.Error.Forbidden{}} = assign(lead, ctx, actor),
             inspect({lead.status, actor})
    end

    assert counts(ctx) == before
    assert length(events_of_type(ctx.tenant, "authz.denied")) == denials

    for lead <- [new_lead, assigned] do
      assert {:error, %Ash.Error.Forbidden{}} = assign(lead, ctx, auditor)
    end

    # Exactly one audited denial per auditor attempt (S2 auditor contract).
    assert length(events_of_type(ctx.tenant, "authz.denied")) == denials + 2
    assert counts(ctx) == before
    {:ok, reloaded} = Sales.fetch(Sales.Lead, new_lead.id, actor: ctx.admin)
    assert reloaded.status == :new
  end

  test "an active assignment is not duplicated, even from a stale struct", ctx do
    stale = fixture_lead!(ctx, "01")
    assert {:ok, _first} = assign(stale, ctx, ctx.admin)
    before = counts(ctx)

    # The caller's struct still says :new; the locked row says :assigned with a queued run.
    assert stale.status == :new
    assert {:error, :assignment_active} = assign(stale, ctx, ctx.admin)
    {:ok, current} = Sales.fetch(Sales.Lead, stale.id, actor: ctx.admin)
    assert {:error, :assignment_active} = assign(current, ctx, ctx.admin)
    assert counts(ctx) == before
  end

  test "a lead in another state or an unknown campaign is refused without writes", ctx do
    %{lead: lead} = assign!(ctx, "05")
    assert %{success: 1} = drain!()
    {:ok, disqualified} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    assert disqualified.status == :disqualified
    before = counts(ctx)

    assert {:error, {:lead_not_assignable, :disqualified}} = assign(disqualified, ctx, ctx.admin)

    assert {:error, _} =
             SDR.assign_lead(fixture_lead!(ctx, "03"),
               campaign_id: Ecto.UUID.generate(),
               actor: ctx.admin
             )

    assert counts(ctx) == before
  end
end

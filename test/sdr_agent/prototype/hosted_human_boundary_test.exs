defmodule SdrAgent.Prototype.HostedHumanBoundaryTest do
  @moduledoc """
  S-B5 reconciliation RED: prototype human rights require a fresh persisted
  nonowner identity, not caller-supplied role/status. Bound-owner precedence
  is tested separately after the S-B2 schema dependency. These checks exercise
  actual resource policies and assignment, never ActorRole in isolation.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Audit.Tenant
  alias SdrAgent.Operations
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Lead
  alias SdrAgent.SDR

  @mutations [
    {Approval, :approve},
    {Approval, :reject},
    {Approval, :revoke},
    {Draft, :edit},
    {Lead, :stop},
    {Lead, :convert},
    {Lead, :nurture}
  ]

  setup do
    fx = G.bound!(auditor: true)
    reviewer = human(:reviewer, fx.tenant)
    %{fx: fx, reviewer: reviewer}
  end

  defp permitted?(resource, action, actor),
    do: Ash.can?({resource, action}, actor, run_queries?: false, maybe_is: false) == true

  defp hidden?(result),
    do: result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)

  for {resource, action} <- @mutations do
    @resource resource
    @action action

    test "#{inspect(resource)} #{@action}: a fabricated human id is denied", ctx do
      assert permitted?(@resource, @action, ctx.reviewer), "ordinary reviewer control"
      forged = %{ctx.reviewer | id: Ecto.UUID.generate()}
      G.enter!(ctx.fx)

      refute permitted?(@resource, @action, forged),
             "prototype action accepted an unpersisted human id"
    end

    test "#{inspect(resource)} #{@action}: role spoof on a real user id is denied", ctx do
      assert permitted?(@resource, @action, ctx.reviewer), "ordinary reviewer control"
      forged = %{ctx.reviewer | role: :admin}
      G.enter!(ctx.fx)

      refute permitted?(@resource, @action, forged),
             "prototype action trusted an admin role over the stored reviewer role"
    end

    test "#{inspect(resource)} #{@action}: a disabled persisted user's stale actor is denied",
         ctx do
      assert permitted?(@resource, @action, ctx.reviewer), "ordinary reviewer control"

      assert {:ok, %{status: :disabled}} =
               Accounts.change_status(ctx.reviewer, :disabled, actor: ctx.fx.admin)

      G.enter!(ctx.fx)

      refute permitted?(@resource, @action, ctx.reviewer),
             "prototype action trusted the stale active status"
    end

    test "#{inspect(resource)} #{@action}: legitimate legacy humans retain the prototype control",
         ctx do
      for actor <- [ctx.reviewer, ctx.fx.admin] do
        assert permitted?(@resource, @action, actor), "ordinary human control"
      end

      G.enter!(ctx.fx)

      for actor <- [ctx.reviewer, ctx.fx.admin] do
        assert permitted?(@resource, @action, actor), "persisted legacy human control"
      end
    end
  end

  for resource <- [AgentDefinition, Tenant], forgery <- [:unknown, :roleless, :higher_role] do
    @resource resource
    @forgery forgery

    test "#{inspect(resource)} metadata: #{@forgery} User cannot use actor_present", ctx do
      control = Ash.read(@resource, actor: ctx.reviewer)
      assert match?({:ok, [_ | _]}, control), "ordinary nonempty metadata control"

      forged =
        case @forgery do
          :unknown -> %{ctx.reviewer | id: Ecto.UUID.generate()}
          :roleless -> %{ctx.reviewer | role: nil}
          :higher_role -> %{ctx.reviewer | role: :admin}
        end

      G.enter!(ctx.fx)
      result = Ash.read(@resource, actor: forged)
      assert hidden?(result), "unvalidated User read prototype metadata"
    end

    test "#{inspect(resource)} metadata: #{@forgery} control retains bound auditor reads", ctx do
      G.enter!(ctx.fx)
      assert {:ok, [_ | _]} = Ash.read(@resource, actor: ctx.fx.auditor)
    end
  end

  test "a random human id cannot assign an already-assigned lead and writes nothing", ctx do
    lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
    campaign = SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
    assert {:ok, assigned} = Sales.update(lead, :assign, %{}, actor: ctx.fx.admin)
    forged = %{ctx.reviewer | id: Ecto.UUID.generate()}
    G.enter!(ctx.fx)
    before = counts()

    assert {:error, %Ash.Error.Forbidden{}} =
             SDR.assign_lead(assigned, campaign_id: campaign.id, actor: forged)

    assert counts() == before
    assert {:ok, %{status: :assigned}} = Sales.fetch(Lead, lead.id, actor: ctx.fx.agent)
  end

  test "an admin role forged on a real reviewer cannot resolve a Failure", ctx do
    SdrAgent.AgentsFixtures.grant!(ctx.fx.tenant, %{}, ctx.fx.admin)
    run = G.run!(ctx.fx)
    invocation = SdrAgent.AgentsFixtures.claude_completed!(run, ctx.fx.agent, "sb5-human-failure")
    failure = SdrAgent.GateFixtures.cause!(invocation, operation_id: run.operation_id)
    forged = %{ctx.reviewer | role: :admin}
    G.enter!(ctx.fx)
    before = counts()

    assert {:error, %Ash.Error.Forbidden{}} =
             Operations.resolve_failure(failure, %{resolution_note: "synthetic refusal"},
               actor: forged
             )

    assert counts() == before

    assert {:ok, %{status: :open}} =
             Operations.get_failure(failure.id, actor: ctx.fx.agent)
  end

  defp counts do
    for table <- ["audit_events", "agent_runs", "operations", "oban_jobs"] do
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, count}
    end
  end
end

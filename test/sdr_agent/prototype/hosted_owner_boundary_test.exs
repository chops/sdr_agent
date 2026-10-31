defmodule SdrAgent.Prototype.HostedOwnerBoundaryTest do
  @moduledoc """
  S-B5 step 2 RED: actual hosted identities cannot inherit legacy reviewer
  powers. Any historical owner association takes precedence over a persisted
  active reviewer; metadata reads and assignment revalidate the principal.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Operations
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Draft
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

  @metadata [
    SdrAgent.Agents.AgentDefinition,
    SdrAgent.Agents.AgentRun,
    SdrAgent.Agents.Decision,
    SdrAgent.Agents.ModelInvocation,
    SdrAgent.Agents.ToolInvocation,
    SdrAgent.Agents.WireWitnessLink,
    SdrAgent.Audit.Tenant,
    SdrAgent.Audit.ProvenanceSnapshot
  ]

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = SdrAgent.AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    _definition = SdrAgent.AgentsFixtures.definition!(ctx.fx.tenant)
    enrolled = H.enrol!(ctx)
    Map.merge(ctx, %{admin: admin, enrolled: enrolled})
  end

  defp permitted?(resource, action, actor),
    do: Ash.can?({resource, action}, actor, run_queries?: false, maybe_is: false) == true

  # Filtered read previews can be :maybe without initial row data. Preserve
  # that distinction from strict identity refusal; real nonempty reads below
  # prove that this preview is not a substitute for the data boundary.
  defp readable?(resource, actor),
    do: Ash.can?({resource, :read}, actor, run_queries?: false, maybe_is: true) == true

  for {resource, action} <- @mutations do
    @resource resource
    @action action

    test "#{inspect(resource)} #{@action}: actual hosted owner cannot inherit reviewer powers",
         ctx do
      H.enter!(ctx)
      assert H.hosted?(ctx.enrolled.user)
      assert permitted?(@resource, @action, ctx.admin), "legacy persisted human control"

      for actor <- [ctx.enrolled.user, %{ctx.enrolled.user | role: :admin}] do
        refute permitted?(@resource, @action, actor), "hosted identity inherited role powers"
      end
    end

    test "#{inspect(resource)} #{@action}: disabled owner history blocks valid reviewer fallback",
         ctx do
      assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id)
      disabled = Ash.get!(Accounts.User, ctx.enrolled.user.id, H.kernel(ctx))
      assert {:ok, restored} = Accounts.change_status(disabled, :active, actor: ctx.admin)
      assert restored.role == :reviewer
      H.enter!(ctx)
      refute H.hosted?(restored)
      refute permitted?(@resource, @action, restored), "historical owner fell back to reviewer"
    end
  end

  for resource <- @metadata do
    @resource resource

    test "#{inspect(resource)}: live owner and auditor read; forged or stale owners do not",
         ctx do
      H.enter!(ctx)
      assert H.hosted?(ctx.enrolled.user)
      assert readable?(@resource, ctx.enrolled.user), "live owner read control"
      assert readable?(@resource, ctx.fx.auditor), "bound auditor read control"

      for actor <- [
            %{ctx.enrolled.user | id: Ecto.UUID.generate()},
            %{ctx.enrolled.user | role: nil},
            %{ctx.enrolled.user | role: :admin}
          ] do
        refute readable?(@resource, actor), "metadata accepted forged User fields"
      end

      assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)
      refute readable?(@resource, ctx.enrolled.user), "stale owner read metadata"
    end

    test "#{inspect(resource)}: an older activation's owner cannot read metadata", ctx do
      third = %{ctx.destination | database_oid: ctx.destination.database_oid + 1_000}
      H.relocate!(ctx, ctx.destination, third, 2)
      H.enter!(ctx)
      refute H.hosted?(ctx.enrolled.user)
      refute readable?(@resource, ctx.enrolled.user)
    end
  end

  test "hosted assignment refuses every caller-present owner option before writes", ctx do
    lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
    campaign = SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
    H.enter!(ctx)
    assert H.hosted?(ctx.enrolled.user)
    before = counts()

    for value <- [nil, lead.owner_user_id, ctx.enrolled.user.id, Ecto.UUID.generate()] do
      assert {:error, %Ash.Error.Forbidden{}} =
               SDR.assign_lead(lead,
                 actor: ctx.enrolled.user,
                 campaign_id: campaign.id,
                 owner_user_id: value
               )

      assert counts() == before
    end
  end

  test "a disabled owner's stale actor cannot use the already-assigned fast path", ctx do
    lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
    campaign = SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
    assert {:ok, assigned} = Sales.update(lead, :assign, %{}, actor: ctx.admin)
    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id)
    H.enter!(ctx)
    before = counts()

    assert {:error, %Ash.Error.Forbidden{}} =
             SDR.assign_lead(assigned, actor: ctx.enrolled.user, campaign_id: campaign.id)

    assert counts() == before
  end

  test "hosted owner cannot read unavailable operations and failures panels", ctx do
    agent = SdrAgent.Actor.system(:agent_runtime, ctx.fx.tenant.id)

    assert {:ok, operation} =
             Operations.create_operation(
               %{
                 kind: :research_lead,
                 queue: :research,
                 subject_resource: "SdrAgent.Sales.Lead",
                 subject_id: Ecto.UUID.generate(),
                 idempotency_key: "sb5-unavailable-panels",
                 correlation_id: Ecto.UUID.generate(),
                 max_attempts: 1
               },
               actor: agent
             )

    assert {:ok, _failure} =
             Operations.open_failure(
               %{
                 subject_resource: "SdrAgent.Operations.Operation",
                 subject_id: operation.id,
                 operation_id: operation.id,
                 class: :reconciliation_required,
                 severity: :warning,
                 message: "Synthetic panel access control",
                 retryable: false
               },
               actor: SdrAgent.Actor.system(:reconciler, ctx.fx.tenant.id)
             )

    for resource <- [Operations.Operation, Operations.Failure] do
      assert {:ok, [_ | _]} =
               resource |> Ash.Query.for_read(:read, %{}, H.kernel(ctx)) |> Ash.read()
    end

    H.enter!(ctx)

    for resource <- [Operations.Operation, Operations.Failure] do
      result = resource |> Ash.Query.for_read(:read, %{}, actor: ctx.enrolled.user) |> Ash.read()
      assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
    end
  end

  test "nonempty metadata reads remain available only while the owner is current", ctx do
    H.enter!(ctx)

    for resource <- [SdrAgent.Agents.AgentDefinition, SdrAgent.Audit.Tenant] do
      assert {:ok, [_ | _]} = Ash.read(resource, actor: ctx.enrolled.user)
    end

    assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.enrolled.user)

    for resource <- [SdrAgent.Agents.AgentDefinition, SdrAgent.Audit.Tenant] do
      result = Ash.read(resource, actor: ctx.enrolled.user)
      assert result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)
    end
  end

  defp counts do
    for table <- ["audit_events", "agent_runs", "operations", "oban_jobs"] do
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, count}
    end
  end
end

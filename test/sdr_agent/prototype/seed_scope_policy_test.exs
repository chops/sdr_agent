defmodule SdrAgent.Prototype.SeedScopePolicyTest do
  @moduledoc """
  Synthetic D-268 C-scope contract: live actor first, transaction markers,
  process registration, same-run event provenance and ordered stored members.
  No policy line or real seed execution is claimed by this scope increment.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.SettingsRevision
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Sequence
  alias SdrAgent.Sales.SequenceStep

  @scope SdrAgent.Prototype.SeedScope

  setup do
    fixture = bound!()
    provenance = F.stored_provenance!(fixture.actor)
    %{actor: fixture.actor, tenant: fixture.tenant, provenance: provenance}
  end

  defp run(ctx, fun) do
    SdrAgent.Audit.transaction(fn ->
      call(@scope, :run, [ctx.actor, %{digest: ctx.provenance.sha256}, fun])
    end)
  end

  defp create(resource, attrs, ctx, run_id) do
    resource
    |> Ash.Changeset.for_create(:seed_prototype, attrs,
      actor: ctx.actor,
      context: %{sdr_seed_run_id: run_id}
    )
    |> Ash.create!()
  end

  defp profile(ctx, run_id) do
    create(
      SettingsRevision,
      %{
        kind: :offering_profile,
        content: F.seed_read().offering_profile,
        note: ctx.provenance.note
      },
      ctx,
      run_id
    )
  end

  defp icp(ctx, run_id) do
    input = F.seed_read().campaign["icp"]

    create(
      IcpDefinition,
      %{
        name: input["name"] <> " " <> Integer.to_string(System.unique_integer([:positive])),
        description: input["description"],
        criteria: input["criteria"],
        seed_provenance_sha256: ctx.provenance.sha256
      },
      ctx,
      run_id
    )
  end

  defp bind!(ref, kind, record) do
    result = call(@scope, :bind, [ref, kind, record])
    assert match?(%{members: _}, result), "expected bound scope, got #{inspect(result)}"
    result
  end

  defp members!(ref, ctx) do
    run_id = call(@scope, :fetch_run_id, [ref])
    profile = profile(ctx, run_id)
    bind!(ref, :offering_profile, profile)
    icp = icp(ctx, run_id)
    bind!(ref, :icp_definition, icp)

    sequence =
      create(
        Sequence,
        %{name: "Synthetic sequence", seed_provenance_sha256: ctx.provenance.sha256},
        ctx,
        run_id
      )

    bind!(ref, :sequence, sequence)

    step =
      create(
        SequenceStep,
        %{
          sequence_id: sequence.id,
          instructions: "One synthetic question.",
          seed_provenance_sha256: ctx.provenance.sha256
        },
        ctx,
        run_id
      )

    bind!(ref, :sequence_step, step)

    campaign =
      create(
        Campaign,
        %{
          name: "Synthetic campaign",
          icp_definition_id: icp.id,
          sequence_id: sequence.id,
          sender_name: "the GTMscape team",
          sender_email: "team@gtmscape.example",
          footer_template_version: "footer/1",
          seed_provenance_sha256: ctx.provenance.sha256
        },
        ctx,
        run_id
      )

    bind!(ref, :campaign, campaign)

    %{
      offering_profile: profile,
      icp_definition: icp,
      sequence: sequence,
      sequence_step: step,
      campaign: campaign
    }
  end

  defp activate(record, actor, scope) do
    record
    |> Ash.Changeset.for_update(:activate, %{},
      actor: actor,
      context: %{sdr_prototype_seed_scope: scope}
    )
    |> Ash.update()
  end

  defp seeder(ctx), do: SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")

  defp prerequisites(:campaign, members, ctx) do
    for kind <- [:icp_definition, :sequence] do
      assert {:ok, _} = Sales.update(members[kind], :activate, %{}, actor: seeder(ctx))
    end
  end

  defp prerequisites(_kind, _members, _ctx), do: :ok

  defp status({:ok, %{status: :active}}), do: :active
  defp status({:error, %Ash.Error.Forbidden{}}), do: :forbidden
  defp status(_other), do: :unexpected

  defp allow(ctx, kind) do
    run(ctx, fn ref ->
      members = members!(ref, ctx)
      prerequisites(kind, members, ctx)
      scope = call(@scope, :fetch, [ref])

      assert call(@scope, :valid?, [
               scope,
               Ash.Changeset.for_update(members[kind], :activate, %{}, actor: ctx.actor),
               ctx.actor
             ])

      assert status(activate(members[kind], ctx.actor, scope)) == :active
      :activated
    end)
  end

  test "policy allows only the complete scope's exact ICP", ctx do
    assert allow(ctx, :icp_definition) == {:ok, :activated}
  end

  test "policy allows only the complete scope's exact sequence", ctx do
    assert allow(ctx, :sequence) == {:ok, :activated}
  end

  test "policy allows only the complete scope's exact campaign", ctx do
    assert allow(ctx, :campaign) == {:ok, :activated}
  end

  test "each narrow policy denies missing, forged and released scope, and a foreign actor", ctx do
    parent = self()

    assert run(ctx, fn ref ->
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])
             forged_actor = %{ctx.actor | tenant_id: Ecto.UUID.generate()}

             for kind <- [:icp_definition, :sequence, :campaign] do
               assert status(activate(members[kind], ctx.actor, nil)) == :forbidden

               assert status(activate(members[kind], ctx.actor, %{scope | ref: make_ref()})) ==
                        :forbidden

               assert status(activate(members[kind], forged_actor, scope)) == :forbidden
             end

             send(parent, {:released, scope, members})
             :denied
           end) == {:ok, :denied}

    assert_received {:released, scope, members}

    for kind <- [:icp_definition, :sequence, :campaign] do
      assert status(activate(members[kind], ctx.actor, scope)) == :forbidden
    end
  end

  test "public domain calls cannot inject even a registered private scope", ctx do
    assert run(ctx, fn ref ->
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])

             for kind <- [:icp_definition, :sequence, :campaign] do
               assert status(
                        Sales.update(members[kind], :activate, %{},
                          actor: ctx.actor,
                          context: %{sdr_prototype_seed_scope: scope}
                        )
                      ) == :forbidden
             end

             :public_refused
           end) == {:ok, :public_refused}
  end

  test "ordinary runtime rejects all three scoped activation allowances", ctx do
    assert run(ctx, fn ref ->
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])
             :ok = PrototypeFixtures.leave_runtime()

             for kind <- [:icp_definition, :sequence, :campaign] do
               assert status(activate(members[kind], ctx.actor, scope)) == :forbidden
             end

             :ordinary_refused
           end) == {:ok, :ordinary_refused}
  end

  test "activation inserts no jobs, models, drafts or outreach", ctx do
    tables =
      ~w(oban_jobs model_invocations tool_invocations drafts draft_revisions approvals delivery_operations delivery_receipts campaign_enrollments)

    counts = fn ->
      for table <- tables, do: Repo.query!("SELECT count(*) FROM " <> table, []).rows
    end

    before = counts.()

    assert run(ctx, fn ref ->
             members = members!(ref, ctx)
             scope = call(@scope, :fetch, [ref])

             for kind <- [:icp_definition, :sequence, :campaign] do
               assert status(activate(members[kind], ctx.actor, scope)) == :active
             end

             :capture_only
           end) == {:ok, :capture_only}

    assert counts.() == before
  end

  test "the existing seeder activation remains unchanged", ctx do
    draft = icp(ctx, nil)
    assert status(Sales.update(draft, :activate, %{}, actor: seeder(ctx))) == :active
  end
end

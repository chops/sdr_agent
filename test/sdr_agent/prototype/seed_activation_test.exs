defmodule SdrAgent.Prototype.SeedActivationTest do
  @moduledoc """
  Seed-scoped activation (supplement 1 r2 §3, Codex R6): the existing
  `:activate` actions of IcpDefinition, Sequence and Campaign admit the
  prototype operator only for the exact seed triple that THIS binding's
  seed created, through `SdrAgent.Sales.Checks.PrototypeSeedScope` (a
  private scope that only `SdrAgent.Prototype.Seed` builds). Deny: no scope,
  an unrelated same-tenant draft, a foreign tenant, a stale or forged
  delegation, ordinary runtime, a forged scope through the domain API. The
  transitions, locks, step requirement and related-active checks stay.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Sales
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Sequence

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp seeder(ctx), do: SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")

  # A draft ICP the operator itself created through the seed action, but
  # outside a seed run: it carries no seed scope.
  # An operator ICP draft outside any seed scope (its own provenance digest,
  # never activated by a seed run).
  defp operator_draft_icp!(ctx) do
    result =
      IcpDefinition
      |> Ash.Changeset.for_create(
        :seed_prototype,
        %{
          name: "Unscoped draft",
          description: "x",
          criteria: %{industries: ["x"]},
          seed_provenance_sha256: String.duplicate("a", 64)
        },
        actor: ctx.actor
      )
      |> Ash.create()

    assert match?({:ok, _}, result),
           "prerequisite: the operator ICP draft returned #{inspect(result)}"

    {:ok, icp} = result
    icp
  end

  # A seeder ICP draft unrelated to the seed; each call has its own name
  # (ICP names are unique per tenant and version).
  defp seeder_draft_icp!(ctx) do
    name = "Unrelated draft " <> Integer.to_string(System.unique_integer([:positive]))

    result =
      Sales.seed_icp_definition(
        %{name: name, description: "x", criteria: %{industries: ["x"]}},
        actor: seeder(ctx)
      )

    assert match?({:ok, _}, result),
           "prerequisite: the seeder ICP draft returned #{inspect(result)}"

    {:ok, icp} = result
    icp
  end

  defp forbidden?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

  test "the seed triple is activated by the operator, as the delegation", ctx do
    summary = call(SdrAgent.Prototype.Seed, :run, [F.seed_read(), ctx.actor])
    assert match?({:ok, %{result: :created}}, summary), "Seed.run/2 returned #{inspect(summary)}"

    for type <-
          ~w(sales.icp_definition.activated sales.sequence.activated sales.campaign.activated) do
      assert [event] = events_of_type(ctx.tenant, type)
      assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
      refute event.actor_id == ctx.fixture.anchor.id
    end
  end

  describe "deny" do
    test "the operator without a seed scope, on its own unscoped draft", ctx do
      icp = operator_draft_icp!(ctx)
      assert forbidden?(Sales.update(icp, :activate, %{}, actor: ctx.actor))
    end

    test "an unrelated same-tenant draft", ctx do
      icp = seeder_draft_icp!(ctx)
      assert forbidden?(Sales.update(icp, :activate, %{}, actor: ctx.actor))
    end

    test "a foreign tenant, a stale or forged delegation", ctx do
      icp = operator_draft_icp!(ctx)

      for actor <- [
            %{ctx.actor | tenant_id: Ecto.UUID.generate()},
            %{ctx.actor | id: Ecto.UUID.generate()}
          ] do
        assert forbidden?(Sales.update(icp, :activate, %{}, actor: actor))
      end
    end

    test "ordinary runtime", ctx do
      icp = operator_draft_icp!(ctx)
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()
      assert forbidden?(Sales.update(icp, :activate, %{}, actor: ctx.actor))
    end

    test "no other operator lifecycle action is admitted", ctx do
      summary = call(SdrAgent.Prototype.Seed, :run, [F.seed_read(), ctx.actor])
      assert match?({:ok, %{icp_id: _}}, summary), "Seed.run/2 returned #{inspect(summary)}"
      {:ok, %{icp_id: icp_id, sequence_id: sequence_id}} = summary
      {:ok, icp} = Sales.fetch(IcpDefinition, icp_id, actor: seeder(ctx))
      {:ok, sequence} = Sales.fetch(Sequence, sequence_id, actor: seeder(ctx))

      assert forbidden?(Sales.update(icp, :retire, %{}, actor: ctx.actor))
      assert forbidden?(Sales.update(sequence, :retire, %{}, actor: ctx.actor))
      assert forbidden?(Sales.update(sequence, :update, %{name: "x"}, actor: ctx.actor))
    end
  end

  describe "unchanged" do
    test "the seeder still activates; an empty sequence and an inactive related ICP still fail",
         ctx do
      icp = seeder_draft_icp!(ctx)

      assert {:ok, %{status: :active} = active} =
               Sales.update(icp, :activate, %{}, actor: seeder(ctx))

      {:ok, empty} = Sales.seed_sequence(%{name: "Empty"}, actor: seeder(ctx))
      assert {:error, _} = Sales.update(empty, :activate, %{}, actor: seeder(ctx))

      draft_icp = seeder_draft_icp!(ctx)

      {:ok, campaign} =
        Sales.seed_campaign(
          %{name: "C", icp_definition_id: draft_icp.id, footer_template_version: "v1"},
          actor: seeder(ctx)
        )

      assert {:error, _} = Sales.update(campaign, :activate, %{}, actor: seeder(ctx))
      # An invalid transition: active → active.
      assert {:error, _} = Sales.update(active, :activate, %{}, actor: seeder(ctx))
    end
  end
end

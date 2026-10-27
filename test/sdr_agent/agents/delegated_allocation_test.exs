defmodule SdrAgent.Agents.DelegatedAllocationTest do
  @moduledoc """
  C2* S2 RED-2 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC4,
  §5 and §7 row 7; Codex plan/entity PASS `aa42492e`: both existing
  allocation policies are kept, owner-form marker AND current admin, with
  the narrow delegated-context alternative satisfying each; ADR-0004
  agent-environment item 9 "Allocations"; T-G3).

  A delegated grant's allocations are written only by PRV inside a
  registered delegated-bundle context
  (`SdrAgent.Agents.Changes.GrantBundle.Delegated.run/2`, modelled on
  `SdrAgent.Agents.ReleaseDecision.Prelocked`): bound to its process,
  transaction and marker, and to the tenant, the parent grant, the
  authorization id and digest and the binding, for exactly that parent.
  The context reaches the allocation changeset as
  `Delegated.context(context)`, as `GrantContext.context/0` does for the
  owner-form bundle.

    * **refused:** PRV with no context; PRV with the owner-form marker; a
      hand-built or tampered context; a context after `run/2` returned; a
      context for another grant, or naming another authorization id or
      digest; any update or release of a delegated grant's allocation, by
      the admin with the owner-form marker or by PRV with any context; and
      an admin adding an allocation to a delegated grant with the marker
      (AC4: "allowed only for PRV inside a registered delegated-bundle
      context").
    * **allowed:** PRV inside a genuine context for exactly its parent; the
      provisioning path, which writes the entry's allocations as PRV.
    * **control:** the owner-form bundle and its marker path are unchanged.

  The delegated parents are SQL-level stand-ins (`delegated_row!/2` in
  `SdrAgent.Test.AgentEnvGrantFixtures`), so the policies are observed on
  rows whose provenance is exactly the GREEN-1 delegated shape.

  RED: the actor type and `Delegated` do not exist (structural `c2star-s2:`
  guards). The admin cases run today's allocation policies, which admit
  them (behavioural). The owner-form control passes now and after GREEN.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.GrantContext
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Clock

  @moduletag :c2star_s2

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      a: delegated_row!(tenant),
      b: delegated_row!(tenant)
    }
  end

  ## Helpers

  defp new_allocation(grant) do
    %{
      grant_id: grant.id,
      grant_revision: grant.revision,
      key: :workshop,
      applies_to: [:b1],
      attempts: 1,
      available_from: ~U[2026-10-30 00:00:00.000000Z],
      available_until: ~U[2026-10-31 00:00:00.000000Z]
    }
  end

  defp create_allocation(grant, actor, context) do
    ModelCallAllocation
    |> Ash.Changeset.for_create(:create, new_allocation(grant), actor: actor, context: context)
    |> Ash.create()
  end

  defp update_allocation(allocation, actor, context) do
    allocation
    |> Ash.Changeset.for_update(:update_terms, %{grant_revision: 1, attempts: 1},
      actor: actor,
      context: context
    )
    |> Ash.update()
  end

  defp release_allocation(allocation, actor, context) do
    allocation
    |> Ash.Changeset.for_update(:release, %{grant_revision: 1}, actor: actor, context: context)
    |> Ash.update()
  end

  defp bindings(grant, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: grant.tenant_id,
        grant_id: grant.id,
        authorization_id: grant.delegated_authorization_id,
        authorization_sha256: grant.delegated_authorization_sha256,
        binding_sha256: rand_hex(32)
      },
      overrides
    )
  end

  defp require_delegated! do
    require_function!(delegated_module(), :run, 2)
    require_function!(delegated_module(), :context, 1)
  end

  # `fun.(context)` inside `Delegated.run/2` in one transaction; the
  # transaction's value, or `{:rolled_back, reason}`.
  defp in_context(bindings, fun) do
    require_delegated!()

    case SdrAgent.Repo.transaction(fn -> invoke(delegated_module(), :run, [bindings, fun]) end) do
      {:ok, value} -> value
      {:error, reason} -> {:rolled_back, reason}
    end
  end

  defp context_of(context), do: invoke(delegated_module(), :context, [context])

  defp assert_forbidden(result, label) do
    assert match?({:error, %Forbidden{}}, result),
           "c2star-s2: #{label}: expected Forbidden, got " <>
             inspect(result, limit: 8, printable_limit: 400)
  end

  defp keys_of(grant), do: grant.id |> reload!() |> Map.fetch!(:allocations) |> Enum.map(& &1.key)

  defp assert_no_new_allocation(ctx, label) do
    for grant <- [ctx.a, ctx.b] do
      assert Enum.sort(keys_of(grant)) == [:daily_use, :rehearsal],
             "c2star-s2: #{label}: an allocation was written to #{grant.id}"
    end
  end

  defp assert_allocations_unchanged(ctx, label) do
    stored = reload!(ctx.a.id).allocations

    assert Enum.map(stored, &{&1.id, &1.attempts, &1.released_at}) ==
             Enum.map(ctx.a.allocations, &{&1.id, &1.attempts, &1.released_at}),
           "c2star-s2: #{label}: a delegated allocation changed"
  end

  ## Refused creates

  describe "creates refused (T-G3)" do
    test "PRV with no context is refused before any write", ctx do
      assert_forbidden(create_allocation(ctx.a, prv(ctx.tenant), %{}), "PRV, no context")
      assert_no_new_allocation(ctx, "PRV, no context")
    end

    test "the owner-form marker does not authorize PRV", ctx do
      result = create_allocation(ctx.a, prv(ctx.tenant), GrantContext.context())
      assert_forbidden(result, "PRV, owner-form marker")
      assert_no_new_allocation(ctx, "PRV, owner-form marker")
    end

    test "a context for another grant is refused", ctx do
      prv = prv(ctx.tenant)
      result = in_context(bindings(ctx.b), &create_allocation(ctx.a, prv, context_of(&1)))
      assert_forbidden(result, "context of grant b used for grant a")
      assert_no_new_allocation(ctx, "another grant")
    end

    test "a context naming another authorization id or digest is refused", ctx do
      prv = prv(ctx.tenant)

      for overrides <- [%{authorization_id: entry_id()}, %{authorization_sha256: rand_hex(32)}] do
        result =
          in_context(bindings(ctx.a, overrides), &create_allocation(ctx.a, prv, context_of(&1)))

        assert_forbidden(result, "context with #{inspect(Map.keys(overrides))}")
      end

      assert_no_new_allocation(ctx, "another authorization")
    end

    test "a hand-built or tampered context is refused", ctx do
      prv = prv(ctx.tenant)
      require_delegated!()

      forged =
        struct(
          delegated_module(),
          Map.merge(bindings(ctx.a), %{ref: make_ref(), xact_id: "1", marker: "sdr_forged"})
        )

      hand_built =
        SdrAgent.Repo.transaction(fn -> create_allocation(ctx.a, prv, context_of(forged)) end)

      assert_forbidden(elem(hand_built, 1), "hand-built context")

      tampered =
        in_context(bindings(ctx.b), fn context ->
          create_allocation(ctx.a, prv, context_of(Map.put(context, :grant_id, ctx.a.id)))
        end)

      assert_forbidden(tampered, "tampered context")
      assert_no_new_allocation(ctx, "forged context")
    end

    test "a context used after run/2 returned is refused", ctx do
      prv = prv(ctx.tenant)
      require_delegated!()

      result =
        SdrAgent.Repo.transaction(fn ->
          stale = invoke(delegated_module(), :run, [bindings(ctx.a), & &1])
          create_allocation(ctx.a, prv, context_of(stale))
        end)

      assert_forbidden(elem(result, 1), "stale context")
      assert_no_new_allocation(ctx, "stale context")
    end

    test "an admin cannot add an allocation to a delegated grant with the owner-form marker",
         ctx do
      result = create_allocation(ctx.a, ctx.admin, GrantContext.context())
      assert_forbidden(result, "admin, owner-form marker, delegated parent")
      assert_no_new_allocation(ctx, "admin create")
    end
  end

  ## Updates and releases

  describe "updates and releases refused (T-G3)" do
    test "the admin cannot update or release a delegated allocation with the owner-form marker",
         ctx do
      allocation = hd(ctx.a.allocations)

      assert_forbidden(
        update_allocation(allocation, ctx.admin, GrantContext.context()),
        "admin update"
      )

      assert_forbidden(
        release_allocation(allocation, ctx.admin, GrantContext.context()),
        "admin release"
      )

      assert_allocations_unchanged(ctx, "admin")
    end

    test "PRV cannot update or release a delegated allocation, with any context", ctx do
      prv = prv(ctx.tenant)
      allocation = hd(ctx.a.allocations)

      assert_forbidden(update_allocation(allocation, prv, GrantContext.context()), "PRV update")
      assert_forbidden(release_allocation(allocation, prv, GrantContext.context()), "PRV release")

      inside =
        in_context(bindings(ctx.a), fn context ->
          {update_allocation(allocation, prv, context_of(context)),
           release_allocation(allocation, prv, context_of(context))}
        end)

      assert match?({{:error, %Forbidden{}}, {:error, %Forbidden{}}}, inside),
             "c2star-s2: PRV update/release inside a genuine context: #{inspect(inside, limit: 6)}"

      assert_allocations_unchanged(ctx, "PRV")
    end
  end

  ## Allowed

  describe "allowed (T-G3)" do
    test "PRV inside a genuine context writes an allocation of exactly its parent", ctx do
      prv = prv(ctx.tenant)
      result = in_context(bindings(ctx.a), &create_allocation(ctx.a, prv, context_of(&1)))

      assert match?({:ok, %ModelCallAllocation{}}, result),
             "c2star-s2: genuine context refused: #{inspect(result, limit: 8, printable_limit: 400)}"

      assert Enum.sort(keys_of(ctx.a)) == [:daily_use, :rehearsal, :workshop]
      assert Enum.sort(keys_of(ctx.b)) == [:daily_use, :rehearsal]
      assert [event] = events_of_type(ctx.tenant, "model.grant.allocation_created")
      assert event.actor_type == :grant_provisioner
    end

    test "the provisioning path writes exactly the entry's allocations, as PRV", ctx do
      env = provisioned!()
      grant = reload!(env.grant.id)

      assert Enum.map(grant.allocations, &{&1.key, &1.attempts}) |> Enum.sort() ==
               Enum.map(env.entry.allocations, &{&1.key, &1.attempts}) |> Enum.sort()

      events =
        ctx.tenant
        |> events_of_type("model.grant.allocation_created")
        |> Enum.filter(&(&1.payload["changes"]["grant_id"] == grant.id))

      assert length(events) == length(env.entry.allocations)
      assert Enum.all?(events, &(&1.actor_type == :grant_provisioner))
    end
  end

  ## Control

  describe "control: the owner-form bundle" do
    test "is unchanged: the admin creates a bundle and writes its allocations with the marker",
         ctx do
      attrs = %{
        name: "G-OWNER",
        purpose: "Owner-form control",
        profile_ids: [:claude_cli_opus],
        total_attempts: 4,
        starts_at: ~U[2026-10-27 00:00:00.000000Z],
        expires_at: ~U[2026-10-31 00:00:00.000000Z],
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 2}]
      }

      result = inert(fn -> Agents.create_grant(attrs, actor: ctx.admin) end)
      assert match?({:ok, %ModelCallGrant{}}, result), "control: #{inspect(result)}"
      {:ok, owner} = result

      added = create_allocation(owner, ctx.admin, GrantContext.context())
      assert match?({:ok, %ModelCallAllocation{}}, added), "control: #{inspect(added)}"
      changed = update_allocation(hd(owner.allocations), ctx.admin, GrantContext.context())
      assert match?({:ok, %ModelCallAllocation{attempts: 1}}, changed), inspect(changed)
      assert Enum.sort(keys_of(owner)) == [:b1, :workshop]
    end
  end
end

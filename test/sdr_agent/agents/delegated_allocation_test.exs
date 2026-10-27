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

  RED-2 supplement (Codex interface rulings `032335a9`, Q3 and Q7; one
  decisive negative action per test, so no refusal is masked by another's
  failure or changed by another's wrong success): the authorization id
  and digest cases, the hand-built and tampered (grant id, marker) cases and
  each update and release are separate tests. Added: a parent that cannot
  be read is never taken for an owner-form parent (Q7); a genuine context
  verifies only in its own process (Q3). Effective CREATE authority is
  owner-form parent AND marker AND current admin, OR delegated parent AND
  PRV AND a verified delegated-bundle context; delegated update and release
  have no allowed actor or context (Q7).

  GREEN-2 harness correction (found in the GREEN-2 run
  `c2-20261027T141238Z-82849`): the provisioning-path test runs without the
  two delegated stand-ins, which the accepted OQ8 rule (no second
  authorization in a tenant) refused as `:another_authorization_provisioned`
  before its assertions. Its assertions are unchanged.
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

  # The delegated stand-ins `a` and `b` are omitted only for a test tagged
  # `delegated_parents: false` (the provisioning path: OQ8 refuses to
  # provision while a delegated grant of another authorization exists in the
  # tenant).
  setup ctx do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()

    parents =
      if Map.get(ctx, :delegated_parents, true),
        do: %{a: delegated_row!(tenant), b: delegated_row!(tenant)},
        else: %{}

    Map.merge(%{tenant: tenant, admin: human(:admin, tenant)}, parents)
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

  defp other_value(:authorization_id), do: entry_id()
  defp other_value(:authorization_sha256), do: rand_hex(32)

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

    for binding <- [:authorization_id, :authorization_sha256] do
      @tag other_binding: binding
      test "a context naming another #{binding} is refused", ctx do
        prv = prv(ctx.tenant)
        overrides = %{ctx.other_binding => other_value(ctx.other_binding)}

        result =
          in_context(bindings(ctx.a, overrides), &create_allocation(ctx.a, prv, context_of(&1)))

        assert_forbidden(result, "context with another #{ctx.other_binding}")
        assert_no_new_allocation(ctx, "another #{ctx.other_binding}")
      end
    end

    test "a hand-built context is refused", ctx do
      prv = prv(ctx.tenant)
      require_delegated!()

      forged =
        struct(
          delegated_module(),
          Map.merge(bindings(ctx.a), %{ref: make_ref(), xact_id: "1", marker: "sdr_forged"})
        )

      hand_built =
        SdrAgent.Repo.transaction(fn -> create_allocation(ctx.a, prv, context_of(forged)) end)

      assert match?({:ok, _result}, hand_built), "fixture: transaction #{inspect(hand_built)}"
      assert_forbidden(elem(hand_built, 1), "hand-built context")
      assert_no_new_allocation(ctx, "hand-built context")
    end

    for field <- [:grant_id, :marker] do
      @tag tampered_field: field
      test "a genuine context with its #{field} changed is refused", ctx do
        prv = prv(ctx.tenant)
        field = ctx.tampered_field
        # The context of grant b, re-pointed at grant a (grant_id), or of
        # grant a with another transaction marker (marker).
        source = if field == :grant_id, do: ctx.b, else: ctx.a
        value = if field == :grant_id, do: ctx.a.id, else: "sdr_tampered_marker"

        tampered =
          in_context(bindings(source), fn context ->
            create_allocation(ctx.a, prv, context_of(Map.put(context, field, value)))
          end)

        assert_forbidden(tampered, "context with a changed #{field}")
        assert_no_new_allocation(ctx, "tampered #{field}")
      end
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

    test "a parent that cannot be read is never taken for an owner-form parent (Q7)", ctx do
      missing = %{ctx.a | id: Ash.UUIDv7.generate()}
      result = create_allocation(missing, ctx.admin, GrantContext.context())
      assert_forbidden(result, "admin, owner-form marker, unreadable parent")
      assert_no_new_allocation(ctx, "unreadable parent")
    end
  end

  ## The registered context (Q3)

  describe "the registered context (Q3)" do
    test "control: a genuine context verifies inside run/2, in its own process", ctx do
      require_function!(delegated_module(), :verify, 1)

      result =
        in_context(bindings(ctx.a), fn context ->
          {context, invoke(delegated_module(), :verify, [context])}
        end)

      assert match?({_context, {:ok, _registered}}, result),
             "c2star-s2: the genuine context did not verify: #{inspect(result, limit: 6)}"

      {context, {:ok, registered}} = result
      assert registered == context
    end

    test "another process cannot verify a genuine context", ctx do
      require_function!(delegated_module(), :verify, 1)

      result =
        in_context(bindings(ctx.a), fn context ->
          fn -> invoke(delegated_module(), :verify, [context]) end
          |> Task.async()
          |> Task.await()
        end)

      assert match?({:error, reason} when is_atom(reason), result),
             "c2star-s2: another process verified the context: #{inspect(result, limit: 6)}"
    end
  end

  ## Updates and releases

  # One decisive negative action per test (supplement): a wrong success of
  # an update cannot mask or change the outcome of a release.
  defp allocation_action(:update, allocation, actor, context),
    do: update_allocation(allocation, actor, context)

  defp allocation_action(:release, allocation, actor, context),
    do: release_allocation(allocation, actor, context)

  describe "updates and releases refused (T-G3)" do
    for action <- [:update, :release] do
      @tag allocation_action: action
      test "the admin cannot #{action} a delegated allocation with the owner-form marker", ctx do
        result =
          allocation_action(
            ctx.allocation_action,
            hd(ctx.a.allocations),
            ctx.admin,
            GrantContext.context()
          )

        assert_forbidden(result, "admin #{ctx.allocation_action}, owner-form marker")
        assert_allocations_unchanged(ctx, "admin #{ctx.allocation_action}")
      end

      @tag allocation_action: action
      test "PRV cannot #{action} a delegated allocation with the owner-form marker", ctx do
        prv = prv(ctx.tenant)

        result =
          allocation_action(
            ctx.allocation_action,
            hd(ctx.a.allocations),
            prv,
            GrantContext.context()
          )

        assert_forbidden(result, "PRV #{ctx.allocation_action}, owner-form marker")
        assert_allocations_unchanged(ctx, "PRV #{ctx.allocation_action}, marker")
      end

      @tag allocation_action: action
      test "PRV cannot #{action} a delegated allocation inside a genuine context", ctx do
        prv = prv(ctx.tenant)
        allocation = hd(ctx.a.allocations)

        result =
          in_context(bindings(ctx.a), fn context ->
            allocation_action(ctx.allocation_action, allocation, prv, context_of(context))
          end)

        assert_forbidden(result, "PRV #{ctx.allocation_action}, genuine context")
        assert_allocations_unchanged(ctx, "PRV #{ctx.allocation_action}, context")
      end
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

    @tag delegated_parents: false
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

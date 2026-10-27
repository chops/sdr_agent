defmodule SdrAgent.Agents.DelegatedProvisioningTest do
  @moduledoc """
  C2* S2 RED-2 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2
  AC1/AC3/AC5, §4.3, §5 and §7 rows 3-6; Codex plan/entity PASS `aa42492e`
  with its binding OQ rulings; the GREEN-1 PASS at `a208a05a`, which moved
  AC1 here; ADR-0004 agent-environment items 4 and 9): the grant
  provisioner (PRV) and the one creating action `ModelCallGrant
  :provision_delegated`, through `SdrAgent.Agents.provision_delegated_grant/2`.

    * **actor (AC1):** `:grant_provisioner` is an `SdrAgent.Actor` type and
      an audit event actor type.
    * **create (T-G1):** PRV, attested in a configured agent environment,
      provisions exactly the registry entry's terms and allocations as a
      `:delegated` grant with no users (OQ2: `name` = the id, `purpose` the
      fixed template), with one `model.grant.provisioned` event carrying
      the id, digest, claim nonce and decision refs, and allocation events
      by PRV. Control: the owner-form `create_grant/2` is unchanged.
    * **refusals (T-G2):** every other actor, and PRV without an
      attestation, attested for another id, outside the agent environment,
      for an unknown id or on a bare action call, is `Forbidden` (audited
      where the call is guarded). The tenant boundary (Codex M1): a
      foreign-tenant PRV at the raw action inside a genuine registration,
      and the singleton tenant's PRV against an environment attesting a
      different tenant on the guarded domain route (one denial in the
      actor's own tenant), each after a positive registration prerequisite. An expired or
      invalid entry, an extra input, a supplied private argument, a live
      database oid other than the binding's (T-B3, S2 half) and another
      authorization already provisioned (OQ8) are a typed
      `ProvisioningRefused`. Nothing is written. Inside an attestation PRV
      still cannot create, change or release a grant.
    * **replay (T-V7, action level):** an identical second call returns the
      same grant marked `:sdr_replayed` and writes nothing; a changed entry
      under the same id is `:grant_conflict`, never a repair; a revoked
      grant is returned revoked (OQ9).
    * **revoke (T-G4):** PRV revokes with no updater, a current admin with
      herself as updater; both bump the revision and record the real actor.
      PRV never revokes an owner-form grant, even through a forged struct
      (the post-lock check). A revoked delegated grant funds no reservation.
    * **terms (AC5):** `:update_terms` and `:release_allocation` of a
      delegated grant are `Forbidden` for every actor, configured or inert,
      and through a forged owner-form struct (`RequireOwnerForm`, after the
      lock). These run on an SQL-level delegated stand-in
      (`delegated_row!/2`), so the admin cases observe today's code.

  Every registry entry is synthetic (`SdrAgent.Test.AgentEnvGrantFixtures`):
  not a cap, not a decision row, never authority. No model, provider or
  network is used; files are private fixture roots.

  RED: the actor type, the action, `provision_delegated_grant/2` and
  `SdrAgent.AgentEnv.Provisioning` do not exist, so most tests stop at an
  explicit `c2star-s2:` presence guard after their fixtures (structural).
  The admin AC5 cases run today's update and release routes (behavioural).
  The two owner-form controls pass now and after GREEN.

  RED-2 supplement (Codex interface rulings `032335a9`, Q4 and Q6; one
  decisive negative action per test, so no refusal is masked by another's
  failure or changed by another's wrong success): each other actor, each
  extra input, each private argument, each action inside an attestation,
  the plain and forged-delegated owner-form revoke, and each AC5 actor,
  mode and action (update_terms, release_allocation) is its own test. The
  guarded refusals assert one `authz.denied` each, appended after rollback,
  with no write and no success event (Q6).

  RED-2 M1 correction (Codex `563e240e`): the former foreign-tenant domain
  test (a PRV of a nonexistent tenant through the guarded route) is
  replaced by the two tenant-boundary tests above. Its refusal would reach
  Guard's denial append for a tenant with no audit chain, which raises
  (`{:error, :chain_not_initialized}` against `{:ok, _}`) under any
  implementation; that Guard defect is tracked separately.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.AgentEnvGrantFixtures

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias Ash.Error.Invalid.NoSuchInput
  alias Ash.Resource.Info
  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv.Registry
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Clock
  alias SdrAgent.Test.AgentEnvFixtures

  @moduletag :c2star_s2

  @terms [
    :name,
    :purpose,
    :profile_ids,
    :total_attempts,
    :per_utc_day_attempts,
    :starts_at,
    :expires_at
  ]
  @allocation_terms [:key, :applies_to, :attempts, :available_from, :available_until]
  @private [:authorization_sha256, :claim_nonce, :decision_refs]

  setup do
    Clock.freeze(now())
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp provisioning(_ctx), do: %{env: provisioning_env!()}

  ## Helpers

  defp purpose(entry) do
    "Delegated agent-environment authorization #{entry.id} " <>
      "(agentenv-1; #{Enum.join(entry.decision_refs, ", ")})"
  end

  defp entry_terms(entry) do
    %{
      name: entry.id,
      purpose: purpose(entry),
      profile_ids: entry.profile_ids,
      total_attempts: entry.total_attempts,
      per_utc_day_attempts: entry.per_utc_day_attempts,
      starts_at: entry.starts_at,
      expires_at: entry.expires_at
    }
  end

  defp allocation_terms(allocations) do
    allocations |> Enum.map(&Map.take(&1, @allocation_terms)) |> Enum.sort_by(& &1.key)
  end

  defp owner_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "G-OWNER",
        purpose: "Owner-form control",
        profile_ids: [:claude_cli_opus],
        total_attempts: 4,
        starts_at: ~U[2026-10-27 00:00:00.000000Z],
        expires_at: ~U[2026-10-31 00:00:00.000000Z],
        allocations: [
          %{key: :b1, applies_to: [:b1], attempts: 2},
          %{
            key: :workshop,
            applies_to: [:b1],
            attempts: 2,
            available_from: ~U[2026-10-30 00:00:00.000000Z]
          }
        ]
      },
      overrides
    )
  end

  # An owner-form grant, created by the current admin with no agent
  # environment configured (the only route that may create one).
  defp owner_grant!(ctx) do
    result = inert(fn -> Agents.create_grant(owner_attrs(), actor: ctx.admin) end)
    assert match?({:ok, %ModelCallGrant{}}, result), "fixture: owner grant: #{inspect(result)}"
    elem(result, 1)
  end

  defp delegated(tenant) do
    Enum.filter(grants(), &(&1.tenant_id == tenant.id and &1.provisioning == :delegated))
  end

  defp assert_nothing_provisioned(ctx, label) do
    assert delegated(ctx.tenant) == [], "c2star-s2: #{label}: a delegated grant was written"
    assert allocations() == [], "c2star-s2: #{label}: an allocation was written"

    assert events_of_type(ctx.tenant, "model.grant.provisioned") == [],
           "c2star-s2: #{label}: a model.grant.provisioned event was appended"
  end

  defp assert_forbidden(result, label) do
    assert match?({:error, %Forbidden{}}, result),
           "c2star-s2: #{label}: expected Forbidden, got " <>
             inspect(result, limit: 8, printable_limit: 400)
  end

  defp assert_refused(result, reason, label) do
    assert refused?(result, reason),
           "c2star-s2: #{label}: expected ProvisioningRefused #{inspect(reason)}, got " <>
             inspect(result, limit: 8, printable_limit: 400)
  end

  defp denials(ctx), do: length(events_of_type(ctx.tenant, "authz.denied"))

  # Inside `within/2`: the registration, by assertion.
  defp registration! do
    result = current()

    assert match?({:ok, _attestation}, result),
           "c2star-s2: no registration inside within/2: #{inspect(result)}"

    elem(result, 1)
  end

  # The raw action, as a caller could build it: for the input and
  # private-argument refusals, which the domain API cannot express.
  defp raw_provision(id, actor, extra, opts) do
    ModelCallGrant
    |> Ash.Changeset.for_create(
      :provision_delegated,
      Map.merge(%{authorization_id: id}, extra),
      [actor: actor] ++ opts
    )
    |> Ash.create()
  end

  defp no_such_input?({:error, %Invalid{errors: errors}}),
    do: Enum.any?(errors, &match?(%NoSuchInput{}, &1))

  defp no_such_input?(_result), do: false

  defp private_arguments! do
    action = require_action!(ModelCallGrant, :provision_delegated)

    for name <- @private do
      argument = Enum.find(action.arguments, &(&1.name == name))

      assert argument && argument.public? == false,
             "c2star-s2: :provision_delegated has no private argument #{inspect(name)}"
    end

    action
  end

  defp label(%Actor{type: type}), do: "system actor #{type}"
  defp label(%{role: role}), do: "human #{role}"

  defp assert_other_actor_refused(ctx, actor) do
    before = denials(ctx)
    assert_forbidden(provision(ctx.env.entry.id, actor: actor), label(actor))

    assert denials(ctx) == before + 1,
           "c2star-s2: #{label(actor)}: the refusal was not audited once (authz.denied)"

    assert_nothing_provisioned(ctx, label(actor))
  end

  # The value a caller could supply for an extra input or a private
  # argument (the true value where one exists).
  defp supplied(:total_attempts, _env), do: 99
  defp supplied(:provisioning, _env), do: :owner_form
  defp supplied(:delegated_authorization_sha256, env), do: env.digest
  defp supplied(:authorization_sha256, env), do: env.digest
  defp supplied(:claim_nonce, env), do: env.claim.nonce
  defp supplied(:decision_refs, env), do: env.entry.decision_refs

  ## AC1

  describe "the PRV actor (AC1)" do
    test ":grant_provisioner is a system actor type and an audit event actor type", ctx do
      assert :grant_provisioner in Actor.types(),
             "c2star-s2: :grant_provisioner is not an SdrAgent.Actor type (AC1)"

      built =
        try do
          {:ok, invoke(Actor, :system, [:grant_provisioner, ctx.tenant.id, prv_id()])}
        rescue
          error -> {:raised, error}
        end

      assert built ==
               {:ok, %Actor{type: :grant_provisioner, id: prv_id(), tenant_id: ctx.tenant.id}}

      one_of = Info.attribute(AuditEvent, :actor_type).constraints[:one_of]

      assert :grant_provisioner in one_of,
             "c2star-s2: AuditEvent.actor_type does not accept :grant_provisioner"
    end
  end

  ## T-G1

  describe "create (T-G1)" do
    setup :provisioning

    test "PRV provisions exactly the entry's terms and allocations as a delegated grant", ctx do
      %{entry: entry, digest: digest} = ctx.env
      assert Registry.validate(entry) == :ok, "fixture: the synthetic entry must validate"

      result = provision(entry.id, actor: prv(ctx.tenant))

      assert match?({:ok, %ModelCallGrant{}}, result),
             "c2star-s2: provisioning failed: #{inspect(result, limit: 8, printable_limit: 400)}"

      {:ok, grant} = result

      assert {grant.provisioning, grant.delegated_authorization_id,
              grant.delegated_authorization_sha256} == {:delegated, entry.id, digest}

      assert {grant.created_by_id, grant.updated_by_id} == {nil, nil}
      assert {grant.status, grant.revision, grant.revoked_at} == {:active, 1, nil}
      assert grant.tenant_id == ctx.tenant.id
      assert Map.take(grant, @terms) == entry_terms(entry)
      assert allocation_terms(grant.allocations) == allocation_terms(entry.allocations)

      for allocation <- grant.allocations do
        assert {allocation.profile_id, allocation.released_at, allocation.grant_revision} ==
                 {nil, nil, 1}
      end

      assert [stored] = delegated(ctx.tenant)
      assert stored.id == grant.id
      assert allocation_terms(stored.allocations) == allocation_terms(entry.allocations)
    end

    test "one model.grant.provisioned event by PRV, allocation events by PRV, no created event",
         ctx do
      %{entry: entry, digest: digest, claim: claim} = ctx.env
      result = provision(entry.id, actor: prv(ctx.tenant))
      assert match?({:ok, %ModelCallGrant{}}, result), "c2star-s2: #{inspect(result)}"
      {:ok, grant} = result

      assert [event] = events_of_type(ctx.tenant, "model.grant.provisioned")

      assert {event.actor_type, event.actor_id, event.subject_id} ==
               {:grant_provisioner, prv_id(), grant.id}

      assert event.payload["arguments"] == %{
               "authorization_id" => entry.id,
               "authorization_sha256" => digest,
               "claim_nonce" => claim.nonce,
               "decision_refs" => entry.decision_refs
             }

      assert event.payload["changes"]["provisioning"] == "delegated"
      assert event.payload["changes"]["delegated_authorization_sha256"] == digest
      assert events_of_type(ctx.tenant, "model.grant.created") == []

      allocation_events = events_of_type(ctx.tenant, "model.grant.allocation_created")
      assert length(allocation_events) == length(entry.allocations)

      for allocation_event <- allocation_events do
        assert allocation_event.actor_type == :grant_provisioner
        assert allocation_event.payload["changes"]["grant_id"] == grant.id
      end
    end

    test "control: an owner-form create_grant is unchanged outside the agent environment", ctx do
      result = inert(fn -> Agents.create_grant(owner_attrs(), actor: ctx.admin) end)
      assert match?({:ok, %ModelCallGrant{}}, result), "control: #{inspect(result)}"
      {:ok, grant} = result

      assert {grant.provisioning, grant.delegated_authorization_id,
              grant.delegated_authorization_sha256} == {:owner_form, nil, nil}

      assert {grant.created_by_id, grant.updated_by_id} == {ctx.admin.id, ctx.admin.id}
      assert [event] = events_of_type(ctx.tenant, "model.grant.created")
      assert event.actor_id == ctx.admin.id
    end
  end

  ## T-G2

  describe "refusals: Forbidden (T-G2)" do
    setup :provisioning

    # One test per actor (supplement: no actor is masked by another's
    # failure, and a wrong success cannot change a later actor's outcome).
    for role <- [:admin, :reviewer, :auditor] do
      @tag actor_role: role
      test "a human #{role} is Forbidden and audited; nothing is written", ctx do
        assert_other_actor_refused(ctx, human(ctx.actor_role, ctx.tenant))
      end
    end

    # Every system actor type but PRV, as compiled at this head.
    for type <- Actor.types() -- [:grant_provisioner] do
      @tag actor_type: type
      test "system actor #{type} is Forbidden and audited; nothing is written", ctx do
        assert_other_actor_refused(ctx, Actor.system(ctx.actor_type, ctx.tenant.id))
      end
    end

    test "PRV with no claim (no attestation) is Forbidden and audited", ctx do
      %{entry: entry} = provisioning_env!(claim: false)
      before = denials(ctx)
      assert_forbidden(provision(entry.id, actor: prv(ctx.tenant)), "no claim")
      assert denials(ctx) == before + 1
      assert_nothing_provisioned(ctx, "no claim")
    end

    test "PRV attested for one authorization is Forbidden for another registry id", ctx do
      attested = test_entry()
      other = test_entry(%{environment_id: "agentenv-2"})
      provisioning_env!(entry: attested, entries: [attested, other])
      assert Registry.fetch(other.id) == {:ok, other}, "fixture: the other entry is registered"
      assert Registry.current() == {:ok, attested}, "fixture: the attested entry is current"

      assert_forbidden(provision(other.id, actor: prv(ctx.tenant)), "another id")
      assert_nothing_provisioned(ctx, "another id")
    end

    test "PRV outside the agent environment is Forbidden", ctx do
      AgentEnvFixtures.unconfigure!()
      assert_forbidden(provision(ctx.env.entry.id, actor: prv(ctx.tenant)), "unconfigured")
      assert_nothing_provisioned(ctx, "unconfigured")
    end

    # Codex M1 (`563e240e`): the tenant boundary is checked at two places,
    # neither of which asks Guard to append a denial to a tenant with no
    # audit chain (a separately tracked Guard defect, not tested here).

    test "a foreign-tenant PRV at the raw action, inside a genuine registration, is Forbidden",
         ctx do
      foreign = prv(Ecto.UUID.generate())
      require_action!(ModelCallGrant, :provision_delegated)

      result =
        within(ctx.env.entry.id, fn ->
          {:registered, registration!(), raw_provision(ctx.env.entry.id, foreign, %{}, [])}
        end)

      assert match?({:registered, _registration, _refused}, result), inspect(result)
      {:registered, registration, refused} = result

      # Prerequisite: a genuine active registration of the same-tenant
      # environment, so no level-:none failure can stand in for the policy.
      assert {registration.level, registration.tenant_id} == {:provisioning, ctx.tenant.id},
             "c2star-s2: prerequisite: no genuine registration: #{inspect(registration)}"

      # The raw action is not guarded: no audit-denial guarantee is claimed.
      assert_forbidden(refused, "foreign-tenant PRV, raw action")
      assert_nothing_provisioned(ctx, "foreign-tenant PRV, raw action")
    end

    test "PRV of a tenant other than the attested tenant is Forbidden and audited once", ctx do
      attested_tenant = Ecto.UUID.generate()
      env = provisioning_env!(tenant_id: attested_tenant)
      assert env.bound.tenant_id == attested_tenant, "fixture: the attested tenant"
      prv = prv(ctx.tenant)
      registration = within(env.entry.id, &registration!/0)

      # Prerequisite: a genuine active registration naming the other tenant.
      assert match?(%{level: :provisioning, tenant_id: ^attested_tenant}, registration),
             "c2star-s2: prerequisite: no registration naming the attested tenant: " <>
               inspect(registration)

      before = denials(ctx)
      assert_forbidden(provision(env.entry.id, actor: prv), "PRV tenant != attested tenant")

      assert denials(ctx) == before + 1,
             "c2star-s2: the refusal was not audited once in the actor's tenant"

      assert_nothing_provisioned(ctx, "PRV tenant != attested tenant")
    end

    test "an unknown authorization id is Forbidden", ctx do
      assert_forbidden(provision(entry_id("test-s2-unknown"), actor: prv(ctx.tenant)), "unknown")
      assert_nothing_provisioned(ctx, "unknown id")
    end

    test "a bare action call outside Provisioning.within/2 is Forbidden", ctx do
      prv = prv(ctx.tenant)
      require_action!(ModelCallGrant, :provision_delegated)
      require_function!(provisioning_module(), :within, 2)
      assert_forbidden(raw_provision(ctx.env.entry.id, prv, %{}, []), "bare action call")
      assert_nothing_provisioned(ctx, "bare action call")
    end

    test "inside an attestation PRV still cannot create a grant", ctx do
      prv = prv(ctx.tenant)

      result =
        within(ctx.env.entry.id, fn ->
          Agents.create_grant(owner_attrs(%{name: "G-PRV"}), actor: prv)
        end)

      assert_forbidden(result, "PRV create inside an attestation")
      assert grants() == []
    end

    test "inside an attestation PRV still cannot change an owner-form grant's terms", ctx do
      owner = owner_grant!(ctx)
      prv = prv(ctx.tenant)

      result =
        within(ctx.env.entry.id, fn ->
          Agents.update_grant_terms(owner, %{expected_revision: 1, name: "renamed"}, actor: prv)
        end)

      assert_forbidden(result, "PRV update_terms inside an attestation")
      stored = reload!(owner.id)
      assert {stored.name, stored.revision} == {"G-OWNER", 1}
    end

    test "inside an attestation PRV still cannot release an owner-form allocation", ctx do
      owner = owner_grant!(ctx)
      prv = prv(ctx.tenant)

      result =
        within(ctx.env.entry.id, fn ->
          Agents.release_allocation(owner, %{expected_revision: 1, key: :workshop}, actor: prv)
        end)

      assert_forbidden(result, "PRV release_allocation inside an attestation")
      stored = reload!(owner.id)
      assert stored.revision == 1
      assert Enum.all?(stored.allocations, &is_nil(&1.released_at))
    end
  end

  describe "refusals: ProvisioningRefused (T-G2)" do
    test "an expired entry is refused, at its expires_at instant", ctx do
      env = provisioning_env!()
      Clock.freeze(env.entry.expires_at)

      result = provision(env.entry.id, actor: prv(ctx.tenant))
      assert_refused(result, :authorization_expired, "expired")
      assert_nothing_provisioned(ctx, "expired")
    end

    test "an invalid entry is refused", ctx do
      entry =
        test_entry(%{
          allocations: [
            alloc(
              :rehearsal,
              2,
              {~U[2026-10-28 00:00:00.000000Z], ~U[2026-10-29 00:00:00.000000Z]}
            ),
            alloc(
              :daily_use,
              5,
              {~U[2026-10-29 00:00:00.000000Z], ~U[2026-10-31 00:00:00.000000Z]}
            )
          ]
        })

      assert Registry.validate(entry) == {:error, :allocations_above_total},
             "fixture: the entry must break exactly one shape rule"

      provisioning_env!(entry: entry)
      result = provision(entry.id, actor: prv(ctx.tenant))
      assert_refused(result, :authorization_invalid, "invalid")
      assert_nothing_provisioned(ctx, "invalid")
    end

    test "the action accepts no attribute and one public argument, authorization_id", _ctx do
      action = require_action!(ModelCallGrant, :provision_delegated)
      assert action.accept == [], "c2star-s2: :provision_delegated must accept no attribute"

      assert for(argument <- action.arguments, argument.public?, do: argument.name) ==
               [:authorization_id]
    end

    for key <- [:total_attempts, :provisioning, :delegated_authorization_sha256, :claim_nonce] do
      @tag extra_input: key
      test "an extra input #{key} is NoSuchInput, inside an attestation", ctx do
        env = provisioning_env!()
        prv = prv(ctx.tenant)
        require_action!(ModelCallGrant, :provision_delegated)
        extra = %{ctx.extra_input => supplied(ctx.extra_input, env)}
        result = within(env.entry.id, fn -> raw_provision(env.entry.id, prv, extra, []) end)

        assert no_such_input?(result),
               "c2star-s2: #{inspect(extra)}: expected NoSuchInput, got " <>
                 inspect(result, limit: 8, printable_limit: 400)

        assert_nothing_provisioned(ctx, "extra input #{ctx.extra_input}")
      end
    end

    for name <- @private do
      @tag private_argument: name
      test "a supplied private #{name} is refused, even with the true value", ctx do
        env = provisioning_env!()
        prv = prv(ctx.tenant)
        private_arguments!()
        name = ctx.private_argument
        value = supplied(name, env)

        result =
          within(env.entry.id, fn ->
            raw_provision(env.entry.id, prv, %{}, private_arguments: %{name => value})
          end)

        assert_refused(result, :inputs_refused, "private #{name}")
        assert_nothing_provisioned(ctx, "private #{name}")
      end
    end

    test "a live database oid other than the binding's is refused (T-B3, S2 half)", ctx do
      {_database, live_oid} = AgentEnvFixtures.live_identity!()
      env = provisioning_env!(database_oid: live_oid + 1)

      result = provision(env.entry.id, actor: prv(ctx.tenant))
      assert_refused(result, :binding_mismatch, "oid + 1")
      assert_nothing_provisioned(ctx, "oid + 1")
    end

    test "a delegated grant of another authorization in the tenant is refused (OQ8)", ctx do
      other = delegated_row!(ctx.tenant)
      env = provisioning_env!()
      assert other.delegated_authorization_id != env.entry.id

      result = provision(env.entry.id, actor: prv(ctx.tenant))
      assert_refused(result, :another_authorization_provisioned, "another authorization")
      assert Enum.map(delegated(ctx.tenant), & &1.id) == [other.id]
      assert events_of_type(ctx.tenant, "model.grant.provisioned") == []
    end
  end

  ## T-V7

  describe "replay (T-V7, action level)" do
    test "an identical second call returns the same grant and writes nothing", ctx do
      env = provisioned!()
      assert Ash.Resource.get_metadata(env.grant, :sdr_replayed) in [nil, false]

      result = provision(env.entry.id, actor: env.prv)
      assert match?({:ok, %ModelCallGrant{}}, result), "c2star-s2: replay: #{inspect(result)}"
      {:ok, replayed} = result

      assert replayed.id == env.grant.id
      assert Ash.Resource.get_metadata(replayed, :sdr_replayed) == true
      assert length(delegated(ctx.tenant)) == 1
      assert length(allocations()) == length(env.entry.allocations)
      assert length(events_of_type(ctx.tenant, "model.grant.provisioned")) == 1

      assert length(events_of_type(ctx.tenant, "model.grant.allocation_created")) ==
               length(env.entry.allocations)
    end

    test "a changed entry under the same id is a conflict, never a repair", ctx do
      env = provisioned!()
      changed = %{env.entry | total_attempts: 7}
      assert Registry.validate(changed) == :ok
      assert Registry.sha256(changed) != env.digest

      # A fresh root, so its claim can name the changed entry's digest.
      provisioning_env!(entry: changed)
      result = provision(changed.id, actor: env.prv)
      assert_refused(result, :grant_conflict, "changed digest")

      stored = reload!(env.grant.id)

      assert {stored.total_attempts, stored.delegated_authorization_sha256, stored.revision} ==
               {6, env.digest, 1}

      assert length(allocations()) == length(env.entry.allocations)
      assert length(events_of_type(ctx.tenant, "model.grant.provisioned")) == 1
    end

    test "a revoked grant is returned revoked, never reactivated (OQ9)", ctx do
      env = provisioned!()
      revoked = Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: ctx.admin)
      assert match?({:ok, %ModelCallGrant{status: :revoked}}, revoked), inspect(revoked)

      result = provision(env.entry.id, actor: env.prv)
      assert match?({:ok, %ModelCallGrant{}}, result), "c2star-s2: replay: #{inspect(result)}"
      {:ok, replayed} = result

      assert {replayed.id, replayed.status, replayed.revision} == {env.grant.id, :revoked, 2}
      assert Ash.Resource.get_metadata(replayed, :sdr_replayed) == true
      assert reload!(env.grant.id).status == :revoked
      assert length(events_of_type(ctx.tenant, "model.grant.provisioned")) == 1
      assert length(events_of_type(ctx.tenant, "model.grant.revoked")) == 1
    end
  end

  ## T-G4

  describe "revoke (T-G4)" do
    test "PRV revokes a delegated grant: no updater, revision bumped, PRV on the event", ctx do
      env = provisioned!()
      result = Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: env.prv)

      assert match?({:ok, %ModelCallGrant{}}, result),
             "c2star-s2: PRV revoke: #{inspect(result, limit: 8, printable_limit: 400)}"

      {:ok, grant} = result

      assert {grant.status, grant.revision, grant.revoked_at, grant.updated_by_id} ==
               {:revoked, 2, now(), nil}

      assert [event] = events_of_type(ctx.tenant, "model.grant.revoked")
      assert {event.actor_type, event.actor_id} == {:grant_provisioner, prv_id()}
      assert event.payload["previous"]["revision"] == 1
    end

    test "a current admin revokes a delegated grant: the admin is the updater", ctx do
      env = provisioned!()
      result = Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: ctx.admin)

      assert match?({:ok, %ModelCallGrant{}}, result),
             "c2star-s2: admin revoke: #{inspect(result)}"

      {:ok, grant} = result

      assert {grant.status, grant.revision, grant.updated_by_id} ==
               {:revoked, 2, ctx.admin.id}

      assert [event] = events_of_type(ctx.tenant, "model.grant.revoked")
      assert {event.actor_type, event.actor_id} == {:user, ctx.admin.id}
    end

    for shape <- [:plain, :forged_delegated] do
      @tag owner_shape: shape
      test "PRV cannot revoke an owner-form grant (#{shape} struct); audited once", ctx do
        env = provisioning_env!()
        owner = owner_grant!(ctx)
        prv = prv(ctx.tenant)
        grant = owner_shape(ctx.owner_shape, owner, env)
        before = denials(ctx)

        assert_forbidden(
          Agents.revoke_grant(grant, %{expected_revision: 1}, actor: prv),
          "PRV revoke, #{ctx.owner_shape} owner-form"
        )

        assert denials(ctx) == before + 1, "c2star-s2: the refusal was not audited once"
        stored = reload!(owner.id)

        assert {stored.status, stored.revision, stored.provisioning, stored.updated_by_id} ==
                 {:active, 1, :owner_form, ctx.admin.id}

        assert events_of_type(ctx.tenant, "model.grant.revoked") == []
      end
    end

    test "a revoked delegated grant funds no reservation", ctx do
      env = provisioned!()
      revoked = Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: ctx.admin)
      assert match?({:ok, %ModelCallGrant{status: :revoked}}, revoked), inspect(revoked)

      result =
        inert(fn ->
          %{run: run, agent: agent} =
            AgentsFixtures.running_run(ctx.tenant, usage_origin: :assignment)

          SdrAgent.AdmissionFixtures.admitting(fn ->
            Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("revoked-delegated"),
              actor: agent
            )
          end)
        end)

      assert match?({:error, %Refused{reason: :no_eligible_grant}}, result),
             "c2star-s2: expected :no_eligible_grant, got #{inspect(result, limit: 6)}"
    end
  end

  ## AC5

  # One decisive negative action per test (supplement): a wrong success of
  # one action can neither mask nor change the outcome of the other.
  defp terms_action(:update_terms, grant, actor),
    do: Agents.update_grant_terms(grant, %{expected_revision: 1, name: "renamed"}, actor: actor)

  defp terms_action(:release_allocation, grant, actor),
    do: Agents.release_allocation(grant, %{expected_revision: 1, key: :daily_use}, actor: actor)

  defp assert_terms_action_refused(ctx, grant, actor, label) do
    before = denials(ctx)
    assert_forbidden(terms_action(ctx.terms_action, grant, actor), label)
    assert denials(ctx) == before + 1, "c2star-s2: #{label}: the refusal was not audited once"
    assert_unchanged(ctx)
  end

  defp assert_unchanged(ctx) do
    stored = reload!(ctx.row.id)

    assert {stored.name, stored.revision, stored.status, stored.updated_by_id} ==
             {ctx.row.name, 1, :active, nil}

    assert Enum.all?(stored.allocations, &is_nil(&1.released_at))
    assert events_of_type(ctx.tenant, "model.grant.terms_changed") == []
    assert events_of_type(ctx.tenant, "model.grant.allocation_released") == []
  end

  # An owner-form struct of the delegated row (forged provenance fields),
  # or a delegated struct of an owner-form row.
  defp forged_owner_form(row, admin) do
    %{
      row
      | provisioning: :owner_form,
        delegated_authorization_id: nil,
        delegated_authorization_sha256: nil,
        created_by_id: admin.id,
        updated_by_id: admin.id
    }
  end

  defp owner_shape(:plain, owner, _env), do: owner

  defp owner_shape(:forged_delegated, owner, env) do
    %{
      owner
      | provisioning: :delegated,
        delegated_authorization_id: env.entry.id,
        delegated_authorization_sha256: env.digest,
        created_by_id: nil,
        updated_by_id: nil
    }
  end

  defp configure_mode!(mode) do
    AgentEnvFixtures.configure!(AgentEnvFixtures.root!("s2"),
      mode: mode,
      nonce: AgentEnvFixtures.nonce()
    )
  end

  describe "delegated terms are immutable (AC5)" do
    setup ctx do
      %{row: delegated_row!(ctx.tenant)}
    end

    for action <- [:update_terms, :release_allocation] do
      @tag terms_action: action
      test "a current admin cannot #{action} a delegated grant (inert)", ctx do
        assert_terms_action_refused(ctx, ctx.row, ctx.admin, "admin, inert, #{ctx.terms_action}")
      end

      @tag terms_action: action
      test "a current admin cannot #{action} a delegated grant (configured, run)", ctx do
        configure_mode!(:run)

        assert_terms_action_refused(
          ctx,
          ctx.row,
          ctx.admin,
          "admin, configured, #{ctx.terms_action}"
        )
      end

      @tag terms_action: action
      test "a forged owner-form struct cannot #{action} a delegated row (post-lock)", ctx do
        forged = forged_owner_form(ctx.row, ctx.admin)

        assert_terms_action_refused(
          ctx,
          forged,
          ctx.admin,
          "admin, forged owner-form, #{ctx.terms_action}"
        )
      end

      @tag terms_action: action
      test "PRV cannot #{action} a delegated grant", ctx do
        prv = prv(ctx.tenant)
        configure_mode!(:provisioning)
        assert_terms_action_refused(ctx, ctx.row, prv, "PRV, #{ctx.terms_action}")
      end
    end
  end
end

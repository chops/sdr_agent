defmodule SdrAgent.Agents.AgentEnvGrantRoutesTest do
  @moduledoc """
  C2* S2 RED-2 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC6
  and §7 row 8; Codex plan/entity PASS `aa42492e`, OQ6 and OQ20; ADR-0004
  agent-environment item 9 "Agent environment: no other route"; T-G5).

  In a configured agent environment, in any mode, the owner-form grant
  routes `create_grant/2`, `update_grant_terms/3` and `release_allocation/3`
  are `Forbidden` (and audited) for every actor, including the seeded admin
  of `SdrAgent.Demo.Seed.run/0`, so the only grant there is the delegated
  one. Revocation stays available: it narrows authority. With
  `SDR_AGENT_ENV` unset the owner-form routes are unchanged (control).

  RED: today the seeded admin's create, change and release succeed in a
  configured agent environment (behavioural). The revoke and inert controls
  pass now and after GREEN.

  RED-2 supplement (Codex interface rulings `032335a9`): each mode and
  route is its own test, with one audited refusal each, so no route's
  refusal is masked by an earlier route's failure.
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Error.Forbidden
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Test.AgentEnvFixtures

  @moduletag :c2star_s2

  setup do
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(&Clock.unfreeze/0)
    {:ok, _counts} = Seed.run()
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()
    seeder = Actor.system(:seeder, tenant_id, "test")
    fixture = Enum.find(Fixtures.users(), &(&1.role == :admin))
    {:ok, admin} = Accounts.get_user(fixture.id, actor: seeder)
    {:ok, grant} = Agents.create_grant(attrs("G-SEEDED"), actor: admin)
    %{tenant: %{id: tenant_id}, admin: admin, grant: grant}
  end

  defp attrs(name) do
    %{
      name: name,
      purpose: "Owner-form route closure",
      profile_ids: [:claude_cli_opus],
      total_attempts: 4,
      starts_at: ~U[2026-01-01 00:00:00.000000Z],
      expires_at: ~U[2026-02-01 00:00:00.000000Z],
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 2},
        %{
          key: :workshop,
          applies_to: [:b1],
          attempts: 2,
          available_from: ~U[2026-01-20 00:00:00.000000Z]
        }
      ]
    }
  end

  defp configure!(mode) do
    root = AgentEnvFixtures.root!("s2routes")
    AgentEnvFixtures.configure!(root, mode: mode, nonce: AgentEnvFixtures.nonce())
  end

  defp denials(ctx), do: length(events_of_type(ctx.tenant, "authz.denied"))

  defp assert_forbidden(result, label) do
    assert match?({:error, %Forbidden{}}, result),
           "c2star-s2: #{label}: expected Forbidden, got " <>
             inspect(result, limit: 8, printable_limit: 400)
  end

  # One route per test (supplement): a wrong success of one route can
  # neither mask nor change the outcome of another.
  defp route(:create, ctx), do: Agents.create_grant(attrs("G-NEW"), actor: ctx.admin)

  defp route(:update_terms, ctx),
    do:
      Agents.update_grant_terms(ctx.grant, %{expected_revision: 1, name: "renamed"},
        actor: ctx.admin
      )

  defp route(:release_allocation, ctx),
    do:
      Agents.release_allocation(ctx.grant, %{expected_revision: 1, key: :workshop},
        actor: ctx.admin
      )

  for mode <- [:run, :provisioning], route <- [:create, :update_terms, :release_allocation] do
    @tag agent_env_mode: mode, grant_route: route
    test "in #{mode} mode the seeded admin's #{route} is Forbidden and audited", ctx do
      configure!(ctx.agent_env_mode)
      before = denials(ctx)
      label = "#{ctx.agent_env_mode} mode: #{ctx.grant_route}"

      assert_forbidden(route(ctx.grant_route, ctx), label)
      assert denials(ctx) == before + 1, "c2star-s2: #{label}: the refusal was not audited once"
      {:ok, grants} = Agents.list_grants(actor: ctx.admin)
      assert Enum.map(grants, &{&1.id, &1.name, &1.revision}) == [{ctx.grant.id, "G-SEEDED", 1}]
      assert Enum.all?(hd(grants).allocations, &is_nil(&1.released_at))
    end
  end

  for mode <- [:run, :provisioning] do
    @tag agent_env_mode: mode
    test "control: in #{mode} mode the seeded admin can still revoke", ctx do
      configure!(ctx.agent_env_mode)
      result = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)

      assert match?({:ok, %ModelCallGrant{status: :revoked, revision: 2}}, result),
             "control: revoke in #{ctx.agent_env_mode} mode: #{inspect(result, limit: 6)}"
    end
  end

  test "control: with SDR_AGENT_ENV unset the owner-form routes are unchanged", ctx do
    AgentEnvFixtures.unconfigure!()

    assert match?(
             {:ok, %ModelCallGrant{}},
             Agents.create_grant(attrs("G-NEW"), actor: ctx.admin)
           )

    updated =
      Agents.update_grant_terms(ctx.grant, %{expected_revision: 1, name: "renamed"},
        actor: ctx.admin
      )

    assert match?({:ok, %ModelCallGrant{revision: 2, name: "renamed"}}, updated), inspect(updated)

    released =
      Agents.release_allocation(elem(updated, 1), %{expected_revision: 2, key: :workshop},
        actor: ctx.admin
      )

    assert match?({:ok, %ModelCallGrant{revision: 3}}, released), inspect(released)
  end
end

defmodule SdrAgent.Agents.ModelCallGrantTest do
  @moduledoc """
  C9 (R0 readiness packet, G5-R0): owner-created real-model call grants and
  their allocations. Only an active human admin, re-read at the time of the
  action, may create, edit, revoke or release; every change is audited with
  its previous values and revision; allocations never exceed the grant total.
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias SdrAgent.Accounts
  alias SdrAgent.Agents

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp g_r0(overrides \\ %{}) do
    Map.merge(
      %{
        name: "G-R0",
        purpose: "Calibration of the two R0 profiles",
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        total_attempts: 4,
        starts_at: ~U[2026-10-12 00:00:00.000000Z],
        expires_at: ~U[2026-10-19 05:59:00.000000Z],
        allocations: [
          %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_opus, attempts: 2},
          %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_sonnet, attempts: 2}
        ]
      },
      overrides
    )
  end

  defp create!(ctx, attrs \\ g_r0()) do
    {:ok, grant} = Agents.create_grant(attrs, actor: ctx.admin)
    grant
  end

  describe "create" do
    test "an active admin creates a grant with its allocations, audited", ctx do
      grant = create!(ctx)

      assert grant.status == :active
      assert grant.revision == 1
      assert grant.created_by_id == ctx.admin.id
      assert grant.total_attempts == 4

      assert grant.allocations |> Enum.map(&{&1.key, &1.profile_id, &1.attempts}) |> Enum.sort() ==
               [{:proof, :claude_cli_opus, 2}, {:proof, :claude_cli_sonnet, 2}]

      assert [event] = events_of_type(ctx.tenant, "model.grant.created")
      assert event.actor_id == ctx.admin.id
    end

    test "reviewers, auditors and every system actor are refused", ctx do
      for role <- [:reviewer, :auditor] do
        user = human(role, ctx.tenant)
        assert {:error, %Forbidden{}} = Agents.create_grant(g_r0(), actor: user)
      end

      for type <- [:agent_runtime, :kernel, :seeder, :scheduler, :reconciler] do
        actor = system_actor(type, ctx.tenant)
        assert {:error, %Forbidden{}} = Agents.create_grant(g_r0(), actor: actor)
      end

      assert {:ok, []} = Agents.list_grants(actor: ctx.admin)
    end

    test "a disabled admin holding a stale struct is refused", ctx do
      stale = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_status(stale, :disabled, actor: ctx.admin)

      assert {:error, %Forbidden{}} = Agents.create_grant(g_r0(), actor: stale)
    end

    test "an admin demoted since the struct was read is refused", ctx do
      stale = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_role(stale, :reviewer, actor: ctx.admin)

      assert {:error, %Forbidden{}} = Agents.create_grant(g_r0(), actor: stale)
    end

    test "allocations above the grant total are refused and nothing is stored", ctx do
      attrs =
        g_r0(%{
          allocations: [
            %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_opus, attempts: 3},
            %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_sonnet, attempts: 2}
          ]
        })

      assert {:error, %Invalid{} = error} = Agents.create_grant(attrs, actor: ctx.admin)
      assert Exception.message(error) =~ "allocations total 5, above the grant total of 4"
      assert {:ok, []} = Agents.list_grants(actor: ctx.admin)
      assert events_of_type(ctx.tenant, "model.grant.created") == []
    end

    test "invalid terms are refused", ctx do
      bad = [
        %{expires_at: ~U[2026-10-12 00:00:00.000000Z]},
        %{profile_ids: []},
        %{profile_ids: [:fake]},
        %{profile_ids: [:claude_cli_gpt]},
        %{total_attempts: 0},
        %{per_utc_day_attempts: 0},
        %{
          allocations: [
            %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_haiku, attempts: 1}
          ]
        },
        %{allocations: [%{key: :proof, applies_to: [], attempts: 1}]},
        %{allocations: [%{key: :b9, applies_to: [:b1], attempts: 1}]},
        %{
          profile_ids: [:claude_cli_opus],
          allocations: [
            %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_sonnet, attempts: 1}
          ]
        }
      ]

      for overrides <- bad do
        assert {:error, %Invalid{}} = Agents.create_grant(g_r0(overrides), actor: ctx.admin),
               "expected refusal for #{inspect(overrides)}"
      end

      assert {:ok, []} = Agents.list_grants(actor: ctx.admin)
    end

    test "two allocations with the same key and profile are refused (nulls not distinct)", ctx do
      attrs =
        g_r0(%{
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 1},
            %{key: :b1, applies_to: [:b1], attempts: 1}
          ]
        })

      assert {:error, %Invalid{}} = Agents.create_grant(attrs, actor: ctx.admin)
    end
  end

  describe "update_terms" do
    test "changes terms and allocations, bumps the revision and audits previous values", ctx do
      grant = create!(ctx)

      {:ok, updated} =
        Agents.update_grant_terms(
          grant,
          %{
            expected_revision: 1,
            total_attempts: 6,
            allocations: [%{key: :proof, profile_id: :claude_cli_opus, attempts: 4}]
          },
          actor: ctx.admin
        )

      assert updated.revision == 2
      assert updated.total_attempts == 6
      assert updated.updated_by_id == ctx.admin.id

      assert updated.allocations |> Enum.map(&{&1.profile_id, &1.attempts}) |> Enum.sort() ==
               [{:claude_cli_opus, 4}, {:claude_cli_sonnet, 2}]

      assert [event] = events_of_type(ctx.tenant, "model.grant.terms_changed")
      assert event.actor_id == ctx.admin.id
    end

    test "a stale revision is refused", ctx do
      grant = create!(ctx)

      {:ok, _} =
        Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 5},
          actor: ctx.admin
        )

      assert {:error, %Invalid{} = error} =
               Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 7},
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "is stale: the grant is at revision 2"
    end

    test "edits that would push allocations above the total are refused atomically", ctx do
      grant = create!(ctx)

      assert {:error, %Invalid{}} =
               Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 3},
                 actor: ctx.admin
               )

      assert {:error, %Invalid{}} =
               Agents.update_grant_terms(
                 grant,
                 %{
                   expected_revision: 1,
                   allocations: [%{key: :proof, profile_id: :claude_cli_opus, attempts: 3}]
                 },
                 actor: ctx.admin
               )

      {:ok, [unchanged]} = Agents.list_grants(actor: ctx.admin)
      assert unchanged.revision == 1
      assert unchanged.total_attempts == 4
    end

    test "non-admins cannot edit", ctx do
      grant = create!(ctx)
      reviewer = human(:reviewer, ctx.tenant)

      assert {:error, %Forbidden{}} =
               Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 9},
                 actor: reviewer
               )

      assert {:error, %Forbidden{}} =
               Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 9},
                 actor: system_actor(:agent_runtime, ctx.tenant)
               )
    end
  end

  describe "revoke and release" do
    test "revocation is terminal and audited", ctx do
      grant = create!(ctx)
      {:ok, revoked} = Agents.revoke_grant(grant, %{expected_revision: 1}, actor: ctx.admin)

      assert revoked.status == :revoked
      assert revoked.revoked_at
      assert [_] = events_of_type(ctx.tenant, "model.grant.revoked")

      assert {:error, %Invalid{}} =
               Agents.update_grant_terms(revoked, %{expected_revision: 2, total_attempts: 9},
                 actor: ctx.admin
               )

      assert {:error, %Invalid{}} =
               Agents.revoke_grant(revoked, %{expected_revision: 2}, actor: ctx.admin)
    end

    test "the owner releases a held allocation early, audited", ctx do
      grant =
        create!(
          ctx,
          g_r0(%{
            name: "G-DEMO",
            total_attempts: 10,
            allocations: [
              %{key: :b1, applies_to: [:b1], attempts: 5},
              %{
                key: :workshop,
                applies_to: [:b1, :b2, :b3, :b4, :b5],
                attempts: 5,
                available_from: ~U[2026-11-06 07:00:00.000000Z]
              }
            ]
          })
        )

      {:ok, released} =
        Agents.release_allocation(grant, %{expected_revision: 1, key: :workshop},
          actor: ctx.admin
        )

      workshop = Enum.find(released.allocations, &(&1.key == :workshop))
      assert workshop.released_at
      assert released.revision == 2
      assert [_] = events_of_type(ctx.tenant, "model.grant.allocation_released")

      reviewer = human(:reviewer, ctx.tenant)

      assert {:error, %Forbidden{}} =
               Agents.release_allocation(released, %{expected_revision: 2, key: :b1},
                 actor: reviewer
               )
    end
  end

  describe "no agent or system changes to grant terms (C9-04 #44)" do
    # Characterization: passes on merged code; not a RED test.
    test "every non-admin and system actor is refused update, revoke and release; nothing changes",
         ctx do
      grant =
        create!(
          ctx,
          g_r0(%{
            name: "G-DEMO",
            total_attempts: 10,
            allocations: [
              %{key: :b1, applies_to: [:b1], attempts: 5},
              %{
                key: :workshop,
                applies_to: [:b1],
                attempts: 5,
                available_from: ~U[2026-11-06 07:00:00.000000Z]
              }
            ]
          })
        )

      before = length(events_of_type(ctx.tenant, "model.grant.created"))

      actors =
        Enum.map([:reviewer, :auditor], &human(&1, ctx.tenant)) ++
          Enum.map(
            [:agent_runtime, :kernel, :seeder, :scheduler, :reconciler],
            &system_actor(&1, ctx.tenant)
          )

      for actor <- actors do
        assert {:error, %Forbidden{}} =
                 Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 9},
                   actor: actor
                 )

        assert {:error, %Forbidden{}} =
                 Agents.revoke_grant(grant, %{expected_revision: 1}, actor: actor)

        assert {:error, %Forbidden{}} =
                 Agents.release_allocation(grant, %{expected_revision: 1, key: :workshop},
                   actor: actor
                 )
      end

      {:ok, stored} = Agents.get_grant(grant.id, actor: ctx.admin)
      assert stored.revision == 1
      assert stored.status == :active
      assert stored.total_attempts == 10
      assert Enum.all?(stored.allocations, &is_nil(&1.released_at))
      assert length(events_of_type(ctx.tenant, "model.grant.created")) == before
      assert [] = events_of_type(ctx.tenant, "model.grant.revoked")
      assert [] = events_of_type(ctx.tenant, "model.grant.allocation_released")
      assert [] = events_of_type(ctx.tenant, "model.grant.terms_changed")
    end
  end

  describe "read" do
    test "admins, auditors and the agent runtime can read; reviewers cannot", ctx do
      create!(ctx)

      assert {:ok, [_]} = Agents.list_grants(actor: ctx.admin)
      assert {:ok, [_]} = Agents.list_grants(actor: human(:auditor, ctx.tenant))
      assert {:ok, [_]} = Agents.list_grants(actor: system_actor(:agent_runtime, ctx.tenant))
      assert {:ok, []} = Agents.list_grants(actor: human(:reviewer, ctx.tenant))
    end
  end

  describe "bundle and boundary (Codex review of 7b5ed9a)" do
    test "allocation actions cannot be called directly, even by an admin", ctx do
      grant = create!(ctx)
      [allocation | _] = grant.allocations

      assert {:error, %Forbidden{}} =
               SdrAgent.Agents.ModelCallAllocation
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   grant_id: grant.id,
                   grant_revision: 1,
                   key: :b1,
                   applies_to: [:b1],
                   attempts: 1
                 },
                 actor: ctx.admin
               )
               |> Ash.create()

      for {action, attrs} <- [
            update_terms: %{attempts: 1, grant_revision: 1},
            release: %{grant_revision: 1}
          ] do
        assert {:error, %Forbidden{}} =
                 allocation
                 |> Ash.Changeset.for_update(action, attrs, actor: ctx.admin)
                 |> Ash.update()
      end

      {:ok, [unchanged]} = Agents.list_grants(actor: ctx.admin)
      assert unchanged.revision == 1
      assert Enum.all?(unchanged.allocations, &is_nil(&1.released_at))
    end

    test "a valid combined edit succeeds whatever order its parts are listed in", ctx do
      for order <- [
            [{:claude_cli_opus, 3}, {:claude_cli_sonnet, 1}],
            [{:claude_cli_sonnet, 1}, {:claude_cli_opus, 3}]
          ] do
        grant = create!(ctx, g_r0(%{name: "G-#{System.unique_integer([:positive])}"}))

        allocations =
          for {profile, n} <- order, do: %{key: :proof, profile_id: profile, attempts: n}

        attrs = %{expected_revision: 1, allocations: allocations}
        assert {:ok, updated} = Agents.update_grant_terms(grant, attrs, actor: ctx.admin)

        assert updated.allocations |> Enum.map(&{&1.profile_id, &1.attempts}) |> Enum.sort() ==
                 [{:claude_cli_opus, 3}, {:claude_cli_sonnet, 1}]
      end
    end

    test "lowering the total together with the allocations is checked on the final state", ctx do
      grant = create!(ctx)

      assert {:ok, updated} =
               Agents.update_grant_terms(
                 grant,
                 %{
                   expected_revision: 1,
                   total_attempts: 3,
                   allocations: [%{key: :proof, profile_id: :claude_cli_opus, attempts: 1}]
                 },
                 actor: ctx.admin
               )

      assert updated.total_attempts == 3

      assert {:error, %Invalid{}} =
               Agents.update_grant_terms(
                 updated,
                 %{
                   expected_revision: 2,
                   profile_ids: [:claude_cli_opus],
                   allocations: [%{key: :proof, profile_id: :claude_cli_opus, attempts: 1}]
                 },
                 actor: ctx.admin
               )

      {:ok, [after_refusal]} = Agents.list_grants(actor: ctx.admin)
      assert after_refusal.revision == 2
      assert after_refusal.profile_ids == [:claude_cli_opus, :claude_cli_sonnet]
    end

    test "every grant-row change is audited with its previous revision; allocations carry the grant revision",
         ctx do
      grant = create!(ctx, g_r0(%{total_attempts: 6}))

      {:ok, grant} =
        Agents.update_grant_terms(
          grant,
          %{expected_revision: 1, allocations: [%{key: :b1, applies_to: [:b1], attempts: 2}]},
          actor: ctx.admin
        )

      {:ok, grant} =
        Agents.release_allocation(grant, %{expected_revision: 2, key: :b1}, actor: ctx.admin)

      assert grant.revision == 3
      b1 = Enum.find(grant.allocations, &(&1.key == :b1))
      assert b1.grant_revision == 3

      [terms] = events_of_type(ctx.tenant, "model.grant.terms_changed")
      assert terms.payload["previous"]["revision"] == 1
      [released] = events_of_type(ctx.tenant, "model.grant.allocation_released")
      assert released.payload["previous"]["revision"] == 2
      [allocation_released] = events_of_type(ctx.tenant, "model.allocation.released")
      assert allocation_released.payload["previous"]["grant_revision"] == 2
      assert length(events_of_type(ctx.tenant, "model.grant.allocation_created")) == 3
    end

    test "events record the operator's current role, not a stale struct's", ctx do
      promoted = new_human(:reviewer, ctx.tenant)
      {:ok, _} = Accounts.change_role(promoted, :admin, actor: ctx.admin)

      assert {:ok, _} = Agents.create_grant(g_r0(), actor: promoted)
      [event] = events_of_type(ctx.tenant, "model.grant.created")
      assert event.actor_role == :admin
    end

    test "release refuses an unknown or already released allocation", ctx do
      grant = create!(ctx)

      assert {:error, %Invalid{}} =
               Agents.release_allocation(grant, %{expected_revision: 1, key: :b2},
                 actor: ctx.admin
               )

      {:ok, grant} =
        Agents.release_allocation(
          grant,
          %{expected_revision: 1, key: :proof, profile_id: :claude_cli_opus},
          actor: ctx.admin
        )

      assert {:error, %Invalid{}} =
               Agents.release_allocation(
                 grant,
                 %{expected_revision: 2, key: :proof, profile_id: :claude_cli_opus},
                 actor: ctx.admin
               )
    end
  end

  describe "bundle inputs (Codex re-review of 40db6a7)" do
    test "allocation inputs are cast with the resource types (string keys, numeric strings)",
         ctx do
      grant = create!(ctx)

      attrs = %{
        expected_revision: 1,
        allocations: [%{"key" => "proof", "profile_id" => "claude_cli_opus", "attempts" => "1"}]
      }

      assert {:ok, updated} = Agents.update_grant_terms(grant, attrs, actor: ctx.admin)
      opus = Enum.find(updated.allocations, &(&1.profile_id == :claude_cli_opus))
      assert opus.attempts == 1
    end

    test "malformed allocation inputs are refused with nothing written", ctx do
      grant = create!(ctx)
      before = length(events(ctx.tenant))

      bad = [
        [%{key: :proof, profile_id: :claude_cli_opus, attempts: "x"}],
        [%{key: :proof, profile_id: :claude_cli_opus, attempts: -1}],
        [%{key: :proof, profile_id: :claude_cli_opus, colour: "blue"}],
        [%{key: :nonsense, attempts: 1, applies_to: [:b1]}],
        [%{key: :b2, applies_to: [:b2]}],
        [:not_a_map]
      ]

      for allocations <- bad do
        attrs = %{expected_revision: 1, allocations: allocations}

        assert {:error, %Invalid{}} = Agents.update_grant_terms(grant, attrs, actor: ctx.admin),
               "expected refusal for #{inspect(allocations)}"
      end

      {:ok, [unchanged]} = Agents.list_grants(actor: ctx.admin)
      assert unchanged.revision == 1
      assert length(events(ctx.tenant)) == before
    end

    test "a pair listed twice is refused, whichever order and whether or not it exists", ctx do
      grant = create!(ctx)
      before = length(events(ctx.tenant))

      for allocations <- [
            [
              %{key: :proof, profile_id: :claude_cli_opus, attempts: 1},
              %{key: :proof, profile_id: :claude_cli_opus, attempts: 2}
            ],
            [
              %{key: :proof, profile_id: :claude_cli_opus, attempts: 2},
              %{key: :proof, profile_id: :claude_cli_opus, attempts: 1}
            ],
            [
              %{key: :b1, applies_to: [:b1], attempts: 1},
              %{key: :b1, applies_to: [:b1], attempts: 1}
            ]
          ] do
        attrs = %{expected_revision: 1, allocations: allocations}
        assert {:error, %Invalid{}} = Agents.update_grant_terms(grant, attrs, actor: ctx.admin)
      end

      {:ok, [unchanged]} = Agents.list_grants(actor: ctx.admin)
      assert unchanged.revision == 1
      assert unchanged.allocations |> Enum.map(& &1.attempts) |> Enum.sort() == [2, 2]
      assert length(events(ctx.tenant)) == before
    end

    test "an allocation update records the exact previous grant revision", ctx do
      grant = create!(ctx)

      {:ok, _} =
        Agents.update_grant_terms(
          grant,
          %{
            expected_revision: 1,
            allocations: [%{key: :proof, profile_id: :claude_cli_opus, attempts: 1}]
          },
          actor: ctx.admin
        )

      [changed] = events_of_type(ctx.tenant, "model.grant.allocation_changed")
      assert changed.payload["previous"]["grant_revision"] == 1
      assert changed.payload["previous"]["attempts"] == 2
    end
  end
end

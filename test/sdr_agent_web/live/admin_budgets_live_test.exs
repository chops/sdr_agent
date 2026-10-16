defmodule SdrAgentWeb.AdminBudgetsLiveTest do
  @moduledoc """
  C9-05 (REQ-R0-9): the admin page's model-call budgets. Only the admin
  reaches the page; every change goes through `SdrAgent.Agents` as the
  signed-in user, after an in-page review step (no browser dialogs); edits,
  revocation and early release carry the revision the admin saw, and a stale
  one is refused with a reload prompt. Times are entered in America/Denver
  and shown in both Denver and UTC.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures

  @opus %{
    "key" => "proof",
    "profile_id" => "claude_cli_opus",
    "applies_to" => ["proof"],
    "attempts" => "2",
    "available_from" => "",
    "available_until" => ""
  }
  @sonnet %{@opus | "profile_id" => "claude_cli_sonnet"}

  defp g_r0_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "G-R0",
        "purpose" => "Calibration of the two R0 profiles",
        "profile_ids" => ["claude_cli_opus", "claude_cli_sonnet"],
        "total_attempts" => "4",
        "per_utc_day_attempts" => "2",
        "starts_at" => "2026-10-12T00:00",
        "expires_at" => "2026-10-18T23:59",
        "allocations" => %{"0" => @opus, "1" => @sonnet}
      },
      overrides
    )
  end

  defp g_r0_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "G-R0",
        purpose: "Calibration of the two R0 profiles",
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        total_attempts: 4,
        starts_at: ~U[2026-10-12 06:00:00.000000Z],
        expires_at: ~U[2026-10-19 05:59:00.000000Z],
        allocations: [
          %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_opus, attempts: 2},
          %{key: :proof, applies_to: [:proof], profile_id: :claude_cli_sonnet, attempts: 2}
        ]
      },
      overrides
    )
  end

  defp admin_view(conn) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    view
  end

  defp open_create(view, rows \\ 2) do
    view |> element("#new-grant") |> render_click()
    for _ <- 1..rows//1, do: view |> element("#add-allocation") |> render_click()
    view
  end

  defp review(view, params) do
    view |> form("#grant-form", grant: params) |> render_submit()
    view
  end

  defp grants!(ctx) do
    {:ok, grants} = Agents.list_grants(actor: ctx.admin)
    grants
  end

  defp create!(ctx, attrs \\ g_r0_attrs()) do
    {:ok, grant} = Agents.create_grant(attrs, actor: ctx.admin)
    grant
  end

  describe "create" do
    test "the admin creates G-R0 through review and confirmation, audited", %{conn: conn} = ctx do
      view = conn |> admin_view() |> open_create() |> review(g_r0_params())

      assert has_element?(view, "#grant-review", "G-R0")
      assert has_element?(view, "#grant-review", "Oct 12, 2026 00:00 MDT")
      assert has_element?(view, "#grant-review", "Oct 12, 2026 06:00 UTC")
      assert has_element?(view, "#review-allocations li", "claude cli opus")
      assert has_element?(view, "#review-allocations li", "claude cli sonnet")
      # Nothing is saved before the confirmation.
      assert grants!(ctx) == []

      view |> element("#confirm-grant") |> render_click()

      assert [grant] = grants!(ctx)
      assert grant.name == "G-R0"
      assert grant.created_by_id == ctx.admin.id
      assert grant.per_utc_day_attempts == 2
      assert grant.starts_at == ~U[2026-10-12 06:00:00.000000Z]
      assert grant.expires_at == ~U[2026-10-19 05:59:00.000000Z]

      assert grant.allocations |> Enum.map(&{&1.key, &1.profile_id, &1.attempts}) |> Enum.sort() ==
               [{:proof, :claude_cli_opus, 2}, {:proof, :claude_cli_sonnet, 2}]

      assert [event] = events_of_type(ctx.tenant, "model.grant.created")
      assert event.actor_id == ctx.admin.id

      refute has_element?(view, "#grant-form")
      assert has_element?(view, "#grants-#{grant.id} [data-status='active']")
      assert has_element?(view, "#grant-revision-#{grant.id}", "1")

      for allocation <- grant.allocations do
        assert has_element?(view, "#allocation-#{allocation.id} [data-attempts='2']")
      end
    end

    test "rows can be added and removed before review", %{conn: conn} = ctx do
      view = conn |> admin_view() |> open_create(3)
      assert has_element?(view, "#allocation-row-2")

      view |> element("#remove-allocation-2") |> render_click()
      refute has_element?(view, "#allocation-row-2")

      view |> review(g_r0_params()) |> element("#confirm-grant") |> render_click()
      assert [%{allocations: [_, _]}] = grants!(ctx)
    end

    test "unparseable input is shown inline and nothing is reviewed or written",
         %{conn: conn} = ctx do
      view =
        conn
        |> admin_view()
        |> open_create()
        |> review(g_r0_params(%{"total_attempts" => "four", "expires_at" => ""}))

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "must be a whole number")
      assert has_element?(view, "#grant-form", "is required")
      assert grants!(ctx) == []
    end

    test "a budget with no profile ticked is flagged on review, before the domain",
         %{conn: conn} = ctx do
      view =
        conn
        |> admin_view()
        |> open_create()
        |> review(Map.delete(g_r0_params(), "profile_ids"))

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "choose at least one profile")
      refute has_element?(view, "#grant-form", "must have 1 or more items")
      assert grants!(ctx) == []
    end

    test "domain refusals are shown inline, the input is kept and nothing is written",
         %{conn: conn} = ctx do
      over = %{"0" => %{@opus | "attempts" => "3"}, "1" => @sonnet}

      view =
        conn |> admin_view() |> open_create() |> review(g_r0_params(%{"allocations" => over}))

      view |> element("#confirm-grant") |> render_click()

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "allocations total 5, above the grant total of 4")
      assert has_element?(view, "#grant-name[value='G-R0']")
      assert grants!(ctx) == []
      assert events_of_type(ctx.tenant, "model.grant.created") == []
    end

    test "Denver times convert to UTC across the Nov 1 2026 DST boundary", %{conn: conn} = ctx do
      view =
        conn
        |> admin_view()
        |> open_create()
        |> review(
          g_r0_params(%{"starts_at" => "2026-10-31T12:00", "expires_at" => "2026-11-02T12:00"})
        )

      assert has_element?(view, "#review-starts-at", "Oct 31, 2026 12:00 MDT")
      assert has_element?(view, "#review-starts-at", "Oct 31, 2026 18:00 UTC")
      assert has_element?(view, "#review-expires-at", "Nov 2, 2026 12:00 MST")
      assert has_element?(view, "#review-expires-at", "Nov 2, 2026 19:00 UTC")

      view |> element("#confirm-grant") |> render_click()

      assert [grant] = grants!(ctx)
      assert grant.starts_at == ~U[2026-10-31 18:00:00.000000Z]
      assert grant.expires_at == ~U[2026-11-02 19:00:00.000000Z]
    end

    test "a wall time in the fall-back fold is resolved visibly on review", %{conn: conn} do
      view =
        conn
        |> admin_view()
        |> open_create()
        |> review(g_r0_params(%{"expires_at" => "2026-11-01T01:30"}))

      assert has_element?(view, "#review-notes", "occurs twice")
      assert has_element?(view, "#review-expires-at", "Nov 1, 2026 07:30 UTC")
    end
  end

  describe "edit terms" do
    test "the admin edits terms through review; the revision is carried", %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)

      view |> element("#edit-grant-#{grant.id}") |> render_click()
      assert has_element?(view, "#grant-total-attempts[value='4']")

      allocations = %{"0" => %{@opus | "attempts" => "4"}, "1" => @sonnet}
      review(view, g_r0_params(%{"total_attempts" => "6", "allocations" => allocations}))

      assert has_element?(view, "#review-changes", "total attempts")
      assert has_element?(view, "#review-changes", "4 → 6")
      assert has_element?(view, "#review-allocations", "attempts 2 → 4")
      assert has_element?(view, "#grant-review", "revision 2")

      view |> element("#confirm-grant") |> render_click()

      assert [updated] = grants!(ctx)
      assert updated.revision == 2
      assert updated.total_attempts == 6
      assert updated.updated_by_id == ctx.admin.id
      assert Enum.find(updated.allocations, &(&1.profile_id == :claude_cli_opus)).attempts == 4
      assert [event] = events_of_type(ctx.tenant, "model.grant.terms_changed")
      assert event.actor_id == ctx.admin.id
    end

    test "an unchanged edit is not saved", %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)
      view |> element("#edit-grant-#{grant.id}") |> render_click()
      review(view, g_r0_params(%{"per_utc_day_attempts" => ""}))

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "Nothing to change")
    end

    test "a stale revision is refused with a reload prompt", %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)
      view |> element("#edit-grant-#{grant.id}") |> render_click()

      # Someone else changes the budget while the form is open.
      {:ok, _} =
        Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 5},
          actor: ctx.admin
        )

      review(view, g_r0_params(%{"total_attempts" => "7", "per_utc_day_attempts" => ""}))
      view |> element("#confirm-grant") |> render_click()

      assert has_element?(view, "#grant-stale", "Someone changed this budget")
      assert [unchanged] = grants!(ctx)
      assert unchanged.revision == 2
      assert unchanged.total_attempts == 5

      view |> element("#reload-grant") |> render_click()
      refute has_element?(view, "#grant-stale")
      assert has_element?(view, "#grant-total-attempts[value='5']")
    end
  end

  describe "edit keeps untouched stored instants (Codex review of PR #134)" do
    # 01:30 on Nov 1 2026 happens twice in Denver; 08:30 UTC is the later (MST) one.
    @later_fold ~U[2026-11-01 08:30:00.000000Z]
    @with_usec ~U[2026-10-12 06:00:00.123456Z]

    defp fold_grant!(ctx) do
      create!(
        ctx,
        g_r0_attrs(%{
          starts_at: @with_usec,
          expires_at: @later_fold,
          total_attempts: 6,
          allocations: [
            %{
              key: :b1,
              applies_to: [:b1],
              attempts: 2,
              available_from: ~U[2026-10-13 07:15:30.654321Z],
              available_until: @later_fold
            }
          ]
        })
      )
    end

    defp open_edit(conn, grant) do
      view = admin_view(conn)
      view |> element("#edit-grant-#{grant.id}") |> render_click()
      view
    end

    test "only the changed term is saved; fold and microsecond instants are kept exactly",
         %{conn: conn} = ctx do
      grant = fold_grant!(ctx)
      view = open_edit(conn, grant)

      # Submit what the form rendered, changing only the total.
      view |> form("#grant-form", grant: %{"total_attempts" => "7"}) |> render_submit()

      assert has_element?(view, "#review-changes", "total attempts")
      refute has_element?(view, "#review-changes", "expires at")
      refute has_element?(view, "#review-changes", "starts at")
      assert has_element?(view, "#review-allocations", "No change to the allocations")

      view |> element("#confirm-grant") |> render_click()

      assert [updated] = grants!(ctx)
      assert updated.revision == 2
      assert updated.total_attempts == 7
      assert updated.expires_at == @later_fold
      assert updated.starts_at == @with_usec

      [allocation] = updated.allocations
      assert allocation.available_until == @later_fold
      assert allocation.available_from == ~U[2026-10-13 07:15:30.654321Z]
      assert events_of_type(ctx.tenant, "model.grant.allocation_changed") == []
    end

    test "an unchanged form round-trips to no change at all", %{conn: conn} = ctx do
      grant = fold_grant!(ctx)
      view = open_edit(conn, grant)

      view |> form("#grant-form") |> render_submit()

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "Nothing to change")
    end

    test "an unchanged fold time previews its stored instant", %{conn: conn} = ctx do
      grant = fold_grant!(ctx)
      view = open_edit(conn, grant)

      assert has_element?(view, "#grant-expires-at-utc", "Nov 1, 2026 08:30 UTC")
      refute has_element?(view, "#grant-expires-at-utc", "earlier of two")
    end

    test "a changed time is parsed with the earlier-instant rule and noted",
         %{conn: conn} = ctx do
      grant = fold_grant!(ctx)
      view = open_edit(conn, grant)

      view
      |> form("#grant-form", grant: %{"expires_at" => "2026-11-01T01:45"})
      |> render_submit()

      assert has_element?(view, "#review-changes", "expires at")
      assert has_element?(view, "#review-notes", "occurs twice")

      view |> element("#confirm-grant") |> render_click()
      assert [%{expires_at: ~U[2026-11-01 07:45:00.000000Z]}] = grants!(ctx)
    end
  end

  describe "review precision and malformed events (Codex review of af2733b)" do
    test "a seconds-only window change shows distinct old and new values", %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)
      view |> element("#edit-grant-#{grant.id}") |> render_click()

      view
      |> form("#grant-form", grant: %{"expires_at" => "2026-10-18T23:59:30"})
      |> render_submit()

      assert has_element?(view, "#review-changes", "Oct 18, 2026 23:59 MDT")
      assert has_element?(view, "#review-changes", "Oct 18, 2026 23:59:30 MDT")
      assert has_element?(view, "#review-changes", "Oct 19, 2026 05:59:30 UTC")
    end

    test "malformed change and review payloads neither crash the page nor write",
         %{conn: conn} = ctx do
      view = conn |> admin_view() |> open_create()

      render_change(view, "change_grant", %{"grant" => "x"})
      render_submit(view, "review_grant", %{"grant" => "x"})
      render_submit(view, "review_grant", %{"grant" => %{"allocations" => "x"}})
      render_submit(view, "review_grant", %{})

      bad_rows = %{
        "0" => "x",
        "1" => %{"key" => "b1", "colour" => "blue", "attempts" => %{"a" => 1}},
        "two" => ["y"]
      }

      render_change(view, "change_grant", %{"grant" => g_r0_params(%{"allocations" => bad_rows})})
      assert has_element?(view, "#allocation-row-1")
      refute has_element?(view, "#allocation-row-0")

      render_submit(view, "review_grant", %{
        "grant" => g_r0_params(%{"allocations" => bad_rows, "name" => %{"x" => "y"}})
      })

      refute has_element?(view, "#grant-review")
      assert has_element?(view, "#grant-form", "attempts is required")
      assert has_element?(view, "#grant-form", "is required")

      render_click(view, "edit_grant", %{"id" => "not-a-uuid"})
      render_click(view, "edit_grant", %{"id" => %{"x" => 1}})
      render_click(view, "remove_allocation", %{"index" => %{"x" => 1}})

      assert has_element?(view, "#model-call-budgets")
      assert grants!(ctx) == []
      assert events_of_type(ctx.tenant, "model.grant.created") == []
    end
  end

  describe "revoke and release" do
    test "revoke asks for confirmation in the page and is terminal", %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)

      view |> element("#revoke-grant-#{grant.id}") |> render_click()
      assert has_element?(view, "#confirm-action", "terminal")
      view |> element("#cancel-action") |> render_click()
      refute has_element?(view, "#confirm-action")
      assert [%{status: :active}] = grants!(ctx)

      view |> element("#revoke-grant-#{grant.id}") |> render_click()
      view |> element("#confirm-action-button") |> render_click()

      assert [%{status: :revoked, revision: 2}] = grants!(ctx)
      assert [event] = events_of_type(ctx.tenant, "model.grant.revoked")
      assert event.actor_id == ctx.admin.id
      assert has_element?(view, "#grants-#{grant.id} [data-status='revoked']")
      refute has_element?(view, "#revoke-grant-#{grant.id}")
      refute has_element?(view, "#edit-grant-#{grant.id}")
    end

    test "a revoke confirmed after someone else's change is refused as stale",
         %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)
      view |> element("#revoke-grant-#{grant.id}") |> render_click()

      {:ok, _} =
        Agents.update_grant_terms(grant, %{expected_revision: 1, total_attempts: 5},
          actor: ctx.admin
        )

      view |> element("#confirm-action-button") |> render_click()
      assert has_element?(view, "#confirm-action", "Someone changed this budget")
      assert [%{status: :active, revision: 2}] = grants!(ctx)
    end

    test "a held allocation is released early with confirmation", %{conn: conn} = ctx do
      grant =
        create!(
          ctx,
          g_r0_attrs(%{
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

      workshop = Enum.find(grant.allocations, &(&1.key == :workshop))
      b1 = Enum.find(grant.allocations, &(&1.key == :b1))
      view = admin_view(conn)

      assert has_element?(view, "#allocation-#{workshop.id} [data-availability='held']")
      assert has_element?(view, "#allocation-#{workshop.id}", "Nov 6, 2026 00:00 MST")
      refute has_element?(view, "#release-#{b1.id}")

      view |> element("#release-#{workshop.id}") |> render_click()
      assert has_element?(view, "#confirm-action", "workshop")
      assert is_nil(Enum.find(hd(grants!(ctx)).allocations, &(&1.key == :workshop)).released_at)

      view |> element("#confirm-action-button") |> render_click()

      [released] = grants!(ctx)
      assert Enum.find(released.allocations, &(&1.key == :workshop)).released_at
      assert released.revision == 2
      assert [_] = events_of_type(ctx.tenant, "model.grant.allocation_released")
      assert has_element?(view, "#allocation-#{workshop.id} [data-availability='released']")
      refute has_element?(view, "#release-#{workshop.id}")
    end
  end

  describe "consumption" do
    test "attempts consumed per budget, per allocation and today are shown",
         %{conn: conn} = ctx do
      grant =
        create!(
          ctx,
          g_r0_attrs(%{
            name: "G-DEMO",
            total_attempts: 10,
            per_utc_day_attempts: 5,
            # Around the frozen test clock.
            starts_at: ~U[2026-01-01 00:00:00.000000Z],
            expires_at: ~U[2026-12-01 00:00:00.000000Z],
            allocations: [
              %{key: :b1, applies_to: [:b1], attempts: 6},
              %{key: :b2, applies_to: [:b2], attempts: 4}
            ]
          })
        )

      run = AgentsFixtures.running_run(ctx.tenant)
      # R0-07 slice B: real calls are admitted only with a promoted tuple.
      SdrAgent.AdmissionFixtures.admit_tuples!()

      for key <- ["c-1", "c-2", "c-3"] do
        attrs = key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"k":"#{key}"}))
        {:ok, _reserved} = Agents.reserve_model_invocation(run.run, attrs, actor: run.agent)
      end

      b1 = Enum.find(grant.allocations, &(&1.key == :b1))
      b2 = Enum.find(grant.allocations, &(&1.key == :b2))
      view = admin_view(conn)

      assert has_element?(view, "#grant-consumed-#{grant.id}[data-consumed='3']", "3 / 10")
      assert has_element?(view, "#grant-today-#{grant.id}", "3 / 5")
      assert has_element?(view, "#allocation-#{b1.id} [data-consumed='3']", "3 / 6")
      assert has_element?(view, "#allocation-#{b2.id} [data-consumed='0']", "0 / 4")
    end
  end

  describe "authorization" do
    for role <- [:reviewer, :auditor] do
      test "#{role} cannot reach the page or send its events", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/"}}} =
                 conn |> sign_in(unquote(role)) |> live(~p"/admin")
      end
    end

    test "an admin demoted while connected is redirected before the domain is called",
         %{conn: conn} = ctx do
      view = conn |> admin_view() |> open_create() |> review(g_r0_params())

      # Another admin remains, so the signed-in one can be demoted.
      _other = SdrAgent.AuditCase.human(:admin, ctx.tenant)
      {:ok, _demoted} = Accounts.change_role(ctx.admin, :reviewer, actor: ctx.admin)

      assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "confirm_grant", %{})
      assert {:ok, []} = Agents.list_grants(actor: ctx.agent)
    end

    test "forged confirmations without a review or a pending action change nothing",
         %{conn: conn} = ctx do
      grant = create!(ctx)
      view = admin_view(conn)

      render_click(view, "confirm_grant", %{})
      render_click(view, "confirm_action", %{"id" => grant.id})

      assert [%{status: :active, revision: 1}] = grants!(ctx)
      assert events_of_type(ctx.tenant, "model.grant.revoked") == []
    end
  end
end

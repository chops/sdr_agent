defmodule SdrAgentWeb.AdminBudgetsAgentEnvTest do
  @moduledoc """
  C2* S2 RED-2 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §2 AC6
  and §7 row 8; Codex plan/entity PASS `aa42492e`, OQ20: the server-side
  refusal is the requirement, and visible controls may show the real
  refusal; T-G5): the admin page's model-call budgets in a configured agent
  environment. The form's create and edit reach the domain as the
  signed-in admin and are refused there, shown inline, with nothing written;
  revoke still works. With `SDR_AGENT_ENV` unset the create path is
  unchanged (control; `admin_budgets_live_test.exs` holds the full owner-form
  suite).

  RED: today the configured create and edit are saved (behavioural). The
  revoke and inert controls pass now and after GREEN.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Test.AgentEnvFixtures

  @moduletag :c2star_s2

  @opus %{
    "key" => "proof",
    "profile_id" => "claude_cli_opus",
    "applies_to" => ["proof"],
    "attempts" => "2",
    "available_from" => "",
    "available_until" => ""
  }
  @sonnet %{@opus | "profile_id" => "claude_cli_sonnet"}
  @refusal "Not permitted for your role. The attempt was refused and recorded."

  defp params(overrides \\ %{}) do
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

  defp attrs do
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
    }
  end

  defp configure! do
    root = AgentEnvFixtures.root!("s2ui")
    AgentEnvFixtures.configure!(root, mode: :run, nonce: AgentEnvFixtures.nonce())
  end

  defp admin_view(conn) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    view
  end

  defp open_create(view) do
    view |> element("#new-grant") |> render_click()
    for _ <- 1..2, do: view |> element("#add-allocation") |> render_click()
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

  defp create!(ctx) do
    {:ok, grant} = Agents.create_grant(attrs(), actor: ctx.admin)
    grant
  end

  test "in a configured agent environment the form's create is refused inline",
       %{conn: conn} = ctx do
    configure!()
    view = conn |> admin_view() |> open_create() |> review(params())
    view |> element("#confirm-grant") |> render_click()

    assert has_element?(view, "#grant-errors", @refusal),
           "c2star-s2: the configured create was not refused inline"

    assert grants!(ctx) == []
    assert events_of_type(ctx.tenant, "model.grant.created") == []
    assert length(denials_of(ctx, ctx.admin)) == 1
  end

  test "in a configured agent environment the form's edit is refused inline",
       %{conn: conn} = ctx do
    grant = create!(ctx)
    configure!()
    view = admin_view(conn)

    view |> element("#edit-grant-#{grant.id}") |> render_click()
    allocations = %{"0" => %{@opus | "attempts" => "4"}, "1" => @sonnet}
    review(view, params(%{"total_attempts" => "6", "allocations" => allocations}))
    view |> element("#confirm-grant") |> render_click()

    assert has_element?(view, "#grant-errors", @refusal),
           "c2star-s2: the configured edit was not refused inline"

    assert [%{revision: 1, total_attempts: 4}] = grants!(ctx)
    assert events_of_type(ctx.tenant, "model.grant.terms_changed") == []
  end

  test "control: in a configured agent environment revoke still works", %{conn: conn} = ctx do
    grant = create!(ctx)
    configure!()
    view = admin_view(conn)

    view |> element("#revoke-grant-#{grant.id}") |> render_click()
    view |> element("#confirm-action-button") |> render_click()

    assert [%{status: :revoked, revision: 2}] = grants!(ctx)
    assert has_element?(view, "#grants-#{grant.id} [data-status='revoked']")
  end

  test "control: with SDR_AGENT_ENV unset the form's create is saved", %{conn: conn} = ctx do
    AgentEnvFixtures.unconfigure!()
    view = conn |> admin_view() |> open_create() |> review(params())
    view |> element("#confirm-grant") |> render_click()

    assert [grant] = grants!(ctx)

    assert {grant.name, grant.created_by_id, grant.provisioning} ==
             {"G-R0", ctx.admin.id, :owner_form}
  end
end

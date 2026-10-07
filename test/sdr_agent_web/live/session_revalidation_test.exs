defmodule SdrAgentWeb.SessionRevalidationTest do
  @moduledoc """
  A connected console socket re-validates its operator on every event and
  navigation (S10 review, PR #17 MF2): the session token must still be
  present and unrevoked and the persisted user active, and the actor passed
  to the domain is the freshly read user. A demoted operator is refused by
  the domain as its new role (and audited); a disabled operator or one
  whose sessions were revoked (password set by an admin) is signed out
  before anything reaches the domain.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Accounts

  setup ctx, do: Map.merge(ctx, drafted!(ctx))

  defp open_as_reviewer(conn, draft) do
    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{draft.id}")
    assert has_element?(view, "#approve-form")
    view
  end

  test "a reviewer demoted to auditor while connected is refused as an auditor",
       %{conn: conn} = ctx do
    reviewer = user!(ctx, :reviewer)
    view = open_as_reviewer(conn, ctx.draft)

    {:ok, _demoted} = Accounts.change_role(reviewer, :auditor, actor: ctx.admin)
    view |> form("#approve-form") |> render_submit()

    assert approvals!(ctx, ctx.draft) == []
    assert [denied] = denials_of(ctx, reviewer)
    assert denied.actor_role == :auditor
    assert has_element?(view, "#current-role", "auditor")
    refute has_element?(view, "#approve-form")
  end

  test "a reviewer disabled while connected is signed out before acting", %{conn: conn} = ctx do
    reviewer = user!(ctx, :reviewer)
    view = open_as_reviewer(conn, ctx.draft)

    {:ok, _disabled} = Accounts.change_status(reviewer, :disabled, actor: ctx.admin)

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             view |> form("#approve-form") |> render_submit()

    assert approvals!(ctx, ctx.draft) == []
  end

  test "a reviewer whose sessions were revoked is signed out before acting",
       %{conn: conn} = ctx do
    reviewer = user!(ctx, :reviewer)
    view = open_as_reviewer(conn, ctx.draft)
    password = String.duplicate("r", 12) <> "-reset-0"

    {:ok, _reset} =
      Accounts.set_password(reviewer, %{password: password, password_confirmation: password},
        actor: ctx.admin
      )

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             view |> form("#approve-form") |> render_submit()

    assert approvals!(ctx, ctx.draft) == []
  end

  test "an unchanged operator keeps acting normally", %{conn: conn} = ctx do
    view = open_as_reviewer(conn, ctx.draft)
    view |> form("#approve-form") |> render_submit()
    assert [_approval] = approvals!(ctx, ctx.draft)
  end
end

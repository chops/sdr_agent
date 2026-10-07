defmodule SdrAgentWeb.NavigationTest do
  @moduledoc """
  S10a app shell: every console route requires a signed-in operator, and the
  navigation shows each role only the views it may use.
  """
  use SdrAgentWeb.OperatorCase, async: false

  @console_paths ["/", "/leads", "/review"]

  test "signed-out visitors are sent to sign-in from every console route", %{conn: conn} do
    for path <- @console_paths do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path)
    end
  end

  test "the shell names the signed-in operator and role", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")

    assert has_element?(view, "#current-operator", "Demo Reviewer")
    assert has_element?(view, "#current-role", "reviewer")
    assert has_element?(view, "#sign-out-link[href='/sign-out'][data-method='delete']")
  end

  for role <- [:admin, :reviewer, :auditor] do
    test "#{role} sees the dashboard, leads and review queue links", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(unquote(role)) |> live(~p"/")

      assert has_element?(view, "#nav-dashboard[href='/']")
      assert has_element?(view, "#nav-leads[href='/leads']")
      assert has_element?(view, "#nav-review[href='/review']")
    end
  end

  test "the auditor is told the console is read-only", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/")
    assert has_element?(view, "#read-only-banner")

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")
    refute has_element?(view, "#read-only-banner")
  end
end

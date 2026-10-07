defmodule SdrAgentWeb.AdminLiveTest do
  @moduledoc """
  S10b Admin / provider status (ADM only): the configured model provider and
  integrations (names only, never credentials), the daily model-call budget
  and per-run limits, today's send quota and the operators. Reviewers and
  auditors are sent back to the dashboard.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures

  test "the admin sees provider, budgets, delivery and operators", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")

    assert has_element?(view, "#model-provider", "Fake")
    assert has_element?(view, "#daily-budget [data-used]")
    assert has_element?(view, "#delivery-adapter", "CaptureAdapter")

    for user <- Fixtures.users() do
      assert has_element?(view, "#users-#{user.id} [data-role='#{user.role}']")
    end
  end

  test "no credential or password material is rendered", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    html = render(view)

    refute html =~ "$2b$"
    refute html =~ "hashed_password"

    for user <- Fixtures.users(), do: refute(html =~ user.password)
  end

  for role <- [:reviewer, :auditor] do
    test "#{role} is redirected away from admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> sign_in(unquote(role)) |> live(~p"/admin")
    end
  end

  test "only the admin's navigation shows Admin", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/")
    assert has_element?(view, "#nav-admin[href='/admin']")

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")
    refute has_element?(view, "#nav-admin")
  end
end

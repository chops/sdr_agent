defmodule SdrAgentWeb.PrototypeBannerTest do
  @moduledoc """
  The whole-dataset banner (amendment item 8 "UI": every prototype page
  shows a fixed `UNVERIFIED (PROTOTYPE)` banner; plan r7 section 3, S4
  `layouts.ex`): the console shell renders it in prototype runtime, and
  never in ordinary runtime; every console LiveView with prototype content
  (dashboard, leads, lead, review, draft, operations, run, audit), viewed
  as the bound prototype auditor, shows it before the page content.
  """
  use SdrAgent.PrototypeCase, async: false

  import Phoenix.Component
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SdrAgentWeb.Endpoint
  @label "UNVERIFIED (PROTOTYPE)"

  defp shell do
    assigns = %{}

    rendered_to_string(~H"""
    <SdrAgentWeb.Layouts.app flash={%{}} current_scope={nil}>
      <p id="page-content">content</p>
    </SdrAgentWeb.Layouts.app>
    """)
  end

  test "ordinary runtime: no prototype banner (control)" do
    html = shell()
    assert html =~ "page-content"
    refute html =~ @label
    refute html =~ "prototype-banner"
  end

  test "prototype runtime: the console shell shows the fixed banner on every page" do
    _fixture = bound!()
    html = shell()
    banner = html |> LazyHTML.from_document() |> LazyHTML.query("#prototype-banner")
    assert Enum.count(banner) == 1, "no single #prototype-banner in the console shell"
    assert LazyHTML.text(banner) =~ @label
    assert LazyHTML.attribute(banner, "role") == ["status"]
  end

  # ------------------------------------------------------------------ pages
  #
  # Every console LiveView that renders prototype content, signed in as the
  # bound prototype auditor (the owner's viewing session; synthetic test
  # password): in prototype runtime the fixed label comes before any page
  # content; in ordinary runtime no page shows it.

  @auditor_password String.duplicate("A", 43)

  defp auditor_conn(ctx) do
    signed_in =
      SdrAgent.Accounts.sign_in(to_string(ctx.fixture.auditor.email), @auditor_password)

    assert match?({:ok, %{role: :auditor}}, signed_in),
           "the bound auditor cannot sign in: #{inspect(signed_in, limit: 3)}"

    {:ok, user} = signed_in

    build_conn()
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp pages(ctx) do
    [
      "/",
      "/leads",
      "/leads/#{ctx.lead.id}",
      "/review",
      "/drafts/#{ctx.draft.id}",
      "/operations",
      "/runs/#{ctx.run.id}",
      "/audit"
    ]
  end

  defp page!(conn, path) do
    result = live(conn, path)

    assert match?({:ok, _view, _html}, result),
           "#{path} did not render: #{inspect(result, limit: 3)}"

    {:ok, _view, html} = result
    html
  end

  test "prototype runtime: every console page shows the banner before its content (bound auditor)" do
    ctx = SdrAgent.PrototypeOutreachFixtures.prototype_drafted!(auditor: true)
    conn = auditor_conn(ctx)

    for path <- pages(ctx) do
      html = page!(conn, path)
      banner = html |> LazyHTML.from_fragment() |> LazyHTML.query("#prototype-banner")
      assert Enum.count(banner) == 1, "#{path}: no single #prototype-banner"
      assert LazyHTML.text(banner) =~ @label, "#{path}: the banner lacks the label"

      {banner_at, _} = :binary.match(html, "id=\"prototype-banner\"")
      {main_at, _} = :binary.match(html, "<main")
      assert banner_at < main_at, "#{path}: the banner does not come before the page content"
    end
  end

  test "ordinary runtime: no console page shows the banner (bound auditor, control)" do
    ctx = SdrAgent.PrototypeOutreachFixtures.prototype_drafted!(auditor: true)
    SdrAgent.PrototypeFixtures.leave_runtime()
    conn = auditor_conn(ctx)

    for path <- pages(ctx) do
      html = page!(conn, path)
      refute html =~ "prototype-banner", "#{path}: a banner in ordinary runtime"
      refute html =~ @label, "#{path}: the label in ordinary runtime"
    end
  end
end

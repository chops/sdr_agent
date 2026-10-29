defmodule SdrAgentWeb.PrototypeBannerTest do
  @moduledoc """
  The whole-dataset banner (amendment r6 item 8 "UI": "Every prototype page
  shows a fixed UNVERIFIED (PROTOTYPE) banner"; plan r7 section 3, S4
  layouts; Codex 05b9be33: the root/sign-in page too).

  - One shared component, `SdrAgentWeb.Layouts.prototype_banner/1`, renders
    the constant label (`role="status"`) in prototype runtime and nothing in
    ordinary runtime. The label is display only, never authority.
  - Every composed page (root layout plus the console shell) holds exactly
    one `#prototype-banner`, as the first element of `<body>`, before any
    page content: the authenticated console pages with prototype content
    viewed as the bound prototype auditor (dashboard, leads, a lead, review,
    a draft, operations, a run, audit, and a captured receipt's payload
    view), and the unauthenticated sign-in page.
  - Ordinary runtime: no page shows the banner or the label, and the console
    shell on its own never renders it.

  Synthetic `.test` data and a synthetic test password only.
  """
  use SdrAgent.PrototypeCase, async: false

  import Phoenix.Component
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import SdrAgent.OutreachFixtures, only: [deliver!: 0, delivery_of!: 2, receipts!: 2]
  import SdrAgent.PrototypeOutreachFixtures, only: [prototype_drafted!: 1, operator_approve: 2]

  @endpoint SdrAgentWeb.Endpoint
  @label "UNVERIFIED (PROTOTYPE)"
  @auditor_password String.duplicate("A", 43)

  defp shell do
    assigns = %{}

    rendered_to_string(~H"""
    <SdrAgentWeb.Layouts.app flash={%{}} current_scope={nil}>
      <p id="page-content">content</p>
    </SdrAgentWeb.Layouts.app>
    """)
  end

  defp component do
    assert function_exported?(SdrAgentWeb.Layouts, :prototype_banner, 1),
           "no shared banner component SdrAgentWeb.Layouts.prototype_banner/1"

    render_component(Function.capture(SdrAgentWeb.Layouts, :prototype_banner, 1), %{})
  end

  # ------------------------------------------------------------------ component

  test "ordinary runtime: the console shell renders no banner (control)" do
    html = shell()
    assert html =~ "page-content"
    refute html =~ @label
    refute html =~ "prototype-banner"
  end

  test "the shared banner component: the label in prototype runtime, nothing in ordinary runtime" do
    _fixture = bound!()
    banner = component() |> LazyHTML.from_fragment() |> LazyHTML.query("#prototype-banner")
    assert Enum.count(banner) == 1, "no single #prototype-banner from the component"
    assert LazyHTML.text(banner) =~ @label
    assert LazyHTML.attribute(banner, "role") == ["status"]

    SdrAgent.PrototypeFixtures.leave_runtime()
    refute component() =~ "prototype-banner"
  end

  # ------------------------------------------------------------------ composed pages

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

  # The console pages with prototype content, plus a captured receipt's
  # payload view (the operator approves inside the window and the delivery
  # is drained, so a receipt exists).
  defp pages(ctx) do
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    deliver!()
    receipt = ctx |> receipts!(delivery_of!(ctx, approval)) |> Enum.find(&(&1.kind == :captured))
    assert receipt, "no captured receipt to view"

    [
      "/",
      "/leads",
      "/leads/#{ctx.lead.id}",
      "/review",
      "/drafts/#{ctx.draft.id}",
      "/operations",
      "/runs/#{ctx.run.id}",
      "/audit",
      "/audit/payloads/#{Base.encode16(receipt.rendered_sha256, case: :lower)}"
    ]
  end

  defp composed!(conn, path) do
    conn = get(conn, path)
    assert conn.status == 200, "#{path}: status #{conn.status}"
    conn.resp_body
  end

  defp one_banner_first!(html, path) do
    document = LazyHTML.from_document(html)
    banners = LazyHTML.query(document, "#prototype-banner")

    assert Enum.count(banners) == 1,
           "#{path}: #{Enum.count(banners)} #prototype-banner elements in the composed page"

    assert LazyHTML.text(banners) =~ @label, "#{path}: the banner lacks the label"

    first = document |> LazyHTML.query("body > *") |> Enum.at(0)

    assert first != nil and LazyHTML.attribute(first, "id") == ["prototype-banner"],
           "#{path}: the banner is not the first element of the body"
  end

  test "prototype runtime: every console page, composed, has exactly one banner before its content (bound auditor)" do
    ctx = prototype_drafted!(auditor: true)
    paths = pages(ctx)
    conn = auditor_conn(ctx)

    for path <- paths, do: one_banner_first!(composed!(conn, path), path)
  end

  test "prototype runtime: the sign-in page has exactly one banner before its content" do
    _fixture = bound!()
    one_banner_first!(composed!(build_conn(), "/sign-in"), "/sign-in")
  end

  test "ordinary runtime: no composed page shows the banner (bound auditor and sign-in, control)" do
    ctx = prototype_drafted!(auditor: true)
    paths = pages(ctx)
    SdrAgent.PrototypeFixtures.leave_runtime()
    conn = auditor_conn(ctx)

    for {conn, path} <- [{build_conn(), "/sign-in"} | Enum.map(paths, &{conn, &1})] do
      html = composed!(conn, path)
      refute html =~ "prototype-banner", "#{path}: a banner in ordinary runtime"
      refute html =~ @label, "#{path}: the label in ordinary runtime"
    end
  end
end

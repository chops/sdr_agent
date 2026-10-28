defmodule SdrAgentWeb.PrototypeBannerTest do
  @moduledoc """
  The whole-dataset banner (amendment item 8 "UI": every prototype page
  shows a fixed `UNVERIFIED (PROTOTYPE)` banner; plan r7 section 3, S4
  `layouts.ex`): the console shell renders it in prototype runtime, and
  never in ordinary runtime.
  """
  use SdrAgent.PrototypeCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

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
end

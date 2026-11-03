defmodule SdrAgentWeb.ProvenanceTest do
  @moduledoc """
  RED (ADR-0026, R2/P6): evidence from an owner intake (`provider:
  :owner_intake`) is labelled "Owner-supplied, unverified" wherever a
  reviewer sees it. `SdrAgentWeb.Provenance` decides that from the
  artifact's provider only, and its component renders the label. The draft
  page shows a banner when any cited artifact is owner-supplied, and the
  citation panel shows the label. The review queue marks such drafts. The
  existing fixture drafts (no owner evidence) show none of this.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import Phoenix.LiveViewTest

  @provenance SdrAgentWeb.Provenance

  defp call(fun, args) do
    assert Code.ensure_loaded?(@provenance), "SdrAgentWeb.Provenance does not exist"

    assert function_exported?(@provenance, fun, length(args)),
           "SdrAgentWeb.Provenance.#{fun}/#{length(args)} is not exported"

    Kernel.apply(Function.capture(@provenance, fun, length(args)), args)
  end

  defp label do
    assert Code.ensure_loaded?(@provenance), "SdrAgentWeb.Provenance does not exist"

    assert function_exported?(@provenance, :label, 1),
           "SdrAgentWeb.Provenance.label/1 is not exported"

    Function.capture(@provenance, :label, 1)
  end

  describe "provider rule" do
    test "the ResearchArtifact provider admits :owner_intake" do
      attribute = Ash.Resource.Info.attribute(SdrAgent.Research.ResearchArtifact, :provider)
      assert :owner_intake in Keyword.fetch!(attribute.constraints, :one_of)
    end

    test "only :owner_intake is owner-supplied" do
      assert call(:owner_supplied?, [%{provider: :owner_intake}])

      for provider <- [:public_dossier, :fixture_web, :fixture_search, :fake_crm, nil] do
        refute call(:owner_supplied?, [%{provider: provider}]), inspect(provider)
      end

      refute call(:owner_supplied?, [nil])
    end

    test "the label renders for owner evidence and is empty otherwise" do
      html = render_component(label(), artifact: %{provider: :owner_intake})
      assert html =~ "Owner-supplied, unverified"
      assert html =~ ~s(data-provenance="owner_intake")
      other = render_component(label(), artifact: %{provider: :public_dossier})
      refute other =~ "Owner-supplied"
    end
  end

  describe "existing drafts (negative control)" do
    setup ctx, do: Map.merge(ctx, drafted!(ctx))

    test "the draft page has no owner banner and the citation panel no owner label",
         %{conn: conn} = ctx do
      assert Code.ensure_loaded?(@provenance), "SdrAgentWeb.Provenance does not exist"
      [citation | _] = citations!(ctx, ctx.revision)
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{ctx.draft.id}")
      refute has_element?(view, "#owner-supplied-evidence")
      view |> element("#revision-body [data-citation-id='#{citation.id}']") |> render_click()
      assert has_element?(view, "#citation-panel [data-provider]")
      refute has_element?(view, "#citation-panel [data-provenance='owner_intake']")
    end

    test "the review queue row has no owner mark", %{conn: conn} = ctx do
      assert Code.ensure_loaded?(@provenance), "SdrAgentWeb.Provenance does not exist"
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/review")
      assert has_element?(view, "#review-queue-#{ctx.draft.id}[data-owner-supplied='false']")
    end
  end
end

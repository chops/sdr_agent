defmodule SdrAgentWeb.RunResearchCapsTest do
  @moduledoc """
  B1-04 visible caps (map row N3 "caps in the run view";
  `docs/product/c4/readiness.md` C4-R11, C4-R14): the run page labels the
  research caps B1-04 enforces (`research_max_sources`,
  `research_max_source_chars`, `research_max_total_source_chars`) "checked
  at use", keeps C5's search and fetch caps "not yet enforced", and shows
  the run's `research_caps` Decision with its outcome.

  Fixture: limits revision 1 lowers the three caps (2 sources, 500 and 600
  characters) so they bite on fixture lead 01; the lead is assigned and its
  research job drained on the Fake model.

  RED: every research cap is labelled "not yet enforced" and the run has
  no `research_caps` Decision.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.SettingsFixtures, only: [content: 2, save!: 3]

  alias SdrAgent.Agents
  alias SdrAgent.Demo.Fixtures

  @moduletag :b1_04

  @enforced [:research_max_sources, :research_max_source_chars, :research_max_total_source_chars]
  @unclaimed [:research_max_search_requests, :research_max_page_fetches]

  setup ctx do
    save!(:offering_profile, Fixtures.offering_profile(), ctx.admin)

    limits =
      content(:operational_limits, %{
        research_max_sources: 2,
        research_max_source_chars: 500,
        research_max_total_source_chars: 600
      })

    save!(:operational_limits, limits, ctx.admin)
    %{run: run} = assign!(ctx, "01")
    drain!()
    %{run: run}
  end

  test "the run page labels B1-04's caps checked at use and shows the run's caps Decision",
       %{conn: conn} = ctx do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/runs/#{ctx.run.id}")

    for field <- @enforced do
      assert has_element?(view, "#run-limit-#{field}", "checked at use"),
             "B1-04: the run page does not label #{field} checked at use"

      refute has_element?(view, "#run-limit-#{field}", "not yet enforced")
    end

    for field <- @unclaimed do
      assert has_element?(view, "#run-limit-#{field}", "not yet enforced"),
             "B1-04: the run page claims C5's #{field} is enforced"
    end

    {:ok, decisions} = Agents.list_decisions(ctx.run.id, actor: ctx.agent)
    caps = Enum.find(decisions, &(&1.kind == :research_caps))
    assert caps, "B1-04: the run recorded no research_caps Decision"

    assert has_element?(view, "#decision-#{caps.id}", "capped"),
           "B1-04: the run page does not show the research caps Decision's outcome"
  end
end

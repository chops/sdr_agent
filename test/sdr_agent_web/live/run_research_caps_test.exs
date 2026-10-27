defmodule SdrAgentWeb.RunResearchCapsTest do
  @moduledoc """
  B1-04 visible caps (map row N3 "caps in the run view";
  `docs/product/c4/readiness.md` C4-R11, C4-R14; plan
  `claude-b1-research-draft-plan-r2.md`): the run page labels the research
  caps B1-04 enforces (`research_max_sources`, `research_max_source_chars`,
  `research_max_total_source_chars`) "checked at use" for a run whose
  pinned definition declares the enforcing `BuildEvidenceBundle` version,
  keeps C5's search and fetch caps "not yet enforced", and shows the run's
  `research_caps` Decision with its outcome. A run pinned to an older
  definition (pre-v4) is labelled "not enforced for this run": the registry
  never implies retroactive enforcement (Codex r1, important).

  Fixture: limits revision 1 lowers the three caps (2 sources, 500 and 600
  characters) so they bite on fixture lead 01; the lead is assigned and its
  research job drained on the Fake model.

  RED: every research cap is labelled "not yet enforced", for every run,
  and the run has no `research_caps` Decision.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.SDRDefinitionFixtures, only: [register_v3!: 1]
  import SdrAgent.SettingsFixtures, only: [content: 2, save!: 3]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
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

  defp open_run(conn, run) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/runs/#{run.id}")
    view
  end

  test "the run page labels B1-04's caps checked at use and shows the run's caps Decision",
       %{conn: conn} = ctx do
    view = open_run(conn, ctx.run)

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

  test "a run pinned to the v3 definition is not labelled as capped", %{conn: conn} = ctx do
    legacy = register_v3!(ctx.tenant.id)
    {:ok, run} = Agents.create_run(AgentsFixtures.run_attrs(legacy), actor: ctx.agent)
    view = open_run(conn, run)

    for field <- @enforced do
      assert has_element?(view, "#run-limit-#{field}", "not enforced for this run"),
             "B1-04: the page of a v3-pinned run does not say #{field} is not enforced for it"

      refute has_element?(view, "#run-limit-#{field}", "checked at use"),
             "B1-04: the page of a v3-pinned run claims #{field} is checked at use"
    end
  end
end

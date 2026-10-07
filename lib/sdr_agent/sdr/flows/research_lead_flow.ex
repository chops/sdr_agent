defmodule SdrAgent.SDR.Flows.ResearchLeadFlow do
  @moduledoc """
  ResearchLeadFlow (spec §7): CRM context → company → recent info search →
  fetch pages → normalize evidence → evaluate evidence quality →
  EvidenceBundle. One Jido Flow, one agent turn (`sdr.research.requested`):

    * "crm" — `GetCRMHistory`;
    * "company" — `FetchCompanyWebsite`;
    * "search" — `SearchCompany` (needs the website URL to skip it);
    * "pages" — `ReadCompanyPage` mapped over the search URLs;
    * "bundle" — `BuildEvidenceBundle`: model extraction, deterministic
      grounding, per-claim quality Decisions; returns the complete agent
      state and emits `sdr.research.completed`.

  Every step is an `SdrAgent.SDR.Action` (one ToolInvocation each, every
  artifact linked to it).
  """
  use Jido.Flow,
    name: "sdr_research_lead_flow",
    description: "Research a lead and build its evidence bundle.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.SDR.Actions

  flow do
    step "crm", action: Actions.GetCRMHistory, params: %{lead_id: input(:lead_id)}
    step "company", action: Actions.FetchCompanyWebsite, params: %{lead_id: input(:lead_id)}

    step "search",
      action: Actions.SearchCompany,
      params: %{lead_id: input(:lead_id), website_url: result("company", :website_url)}

    map "pages",
      collection: result("search", :urls),
      action: Actions.ReadCompanyPage,
      params: %{lead_id: input(:lead_id), url: item()}

    step "bundle",
      action: Actions.BuildEvidenceBundle,
      params: %{
        lead_id: input(:lead_id),
        crm: result("crm"),
        company: result("company"),
        search: result("search"),
        pages: result("pages")
      }

    output(result("bundle"))
  end
end

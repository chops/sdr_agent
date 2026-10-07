defmodule SdrAgent.SDR.SDRAgent do
  @moduledoc """
  The SDR agent (spec §4 "One SDRAgent initially"), a Jido v3 agent
  (ADR-0003). "Jido decides": each signal selects one Action or Flow; the
  application's Ash domains govern every write those make.

  State is only the assignment's working state — `tenant_id`, `campaign_id`,
  `lead_id`, `phase`, `objective`, `evidence_ids`, `qualification`
  (`{id, qualified, score}`), `proposal_id`, `budget` (`{model_calls,
  tool_calls}`, mirrored from the AgentRun) and `run_id` — never CRM
  records; Postgres holds everything else (spec §12).

  Routes (spec §5–§7):

    * `sdr.lead.assigned` → `AcceptAssignment`
    * `sdr.research.requested` → `ResearchLeadFlow`
    * `sdr.research.completed` → `RequestQualification`
    * `sdr.qualification.requested` → `ScoreLead`
    * `sdr.qualification.completed` → `PlanOutreach`
    * `sdr.draft.requested` → `PrepareOutreachFlow`
    * `sdr.lead.suppressed`, `sdr.campaign.paused` → `HaltAssignment`

  `sdr.draft.completed` is the hand-off to S8 and is not routed here. There
  is deliberately no send action (spec §6).

  `register/1` records this definition (allowed actions, prompt and schema
  refs with hashes, model policy) as the `SDRAgent` v1 AgentDefinition.
  """
  use Jido.Agent,
    name: "sdr_agent",
    description: "Researches, qualifies and prepares outreach for one assigned lead."

  alias SdrAgent.Agents
  alias SdrAgent.SDR.Actions
  alias SdrAgent.SDR.Flows
  alias SdrAgent.SDR.Prompts
  alias SdrAgent.SDR.Schemas

  @phases [
    :discover,
    :research,
    :qualify,
    :plan,
    :personalize,
    :draft,
    :validate,
    :review,
    :queue,
    :deliver,
    :observe,
    :reply,
    :stop
  ]
  @version 1

  agent do
    schema(
      Zoi.object(%{
        tenant_id: Zoi.string() |> Zoi.optional(),
        campaign_id: Zoi.string() |> Zoi.optional(),
        lead_id: Zoi.string() |> Zoi.optional(),
        run_id: Zoi.string() |> Zoi.optional(),
        phase: Zoi.enum(@phases) |> Zoi.default(:discover),
        objective: Zoi.string() |> Zoi.default(""),
        evidence_ids: Zoi.list(Zoi.string()) |> Zoi.default([]),
        qualification:
          Zoi.object(%{id: Zoi.string(), qualified: Zoi.boolean(), score: Zoi.integer()})
          |> Zoi.optional(),
        proposal_id: Zoi.string() |> Zoi.optional(),
        budget:
          Zoi.object(%{model_calls: Zoi.integer(), tool_calls: Zoi.integer()})
          |> Zoi.default(%{model_calls: 0, tool_calls: 0})
      })
    )

    metadata(%{domain: "sdr", spec: "sdr-architecture §4"})
  end

  routes do
    signal_source("/sdr_agent/sdr")

    route("sdr.lead.assigned", Actions.AcceptAssignment)
    route("sdr.research.requested", Flows.ResearchLeadFlow)
    route("sdr.research.completed", Actions.RequestQualification)
    route("sdr.qualification.requested", Actions.ScoreLead)
    route("sdr.qualification.completed", Actions.PlanOutreach)
    route("sdr.draft.requested", Flows.PrepareOutreachFlow)
    route("sdr.lead.suppressed", Actions.HaltAssignment)
    route("sdr.campaign.paused", Actions.HaltAssignment)
  end

  @actions [
    Actions.AcceptAssignment,
    Actions.GetCRMHistory,
    Actions.FetchCompanyWebsite,
    Actions.SearchCompany,
    Actions.ReadCompanyPage,
    Actions.BuildEvidenceBundle,
    Actions.RequestQualification,
    Actions.ScoreLead,
    Actions.PlanOutreach,
    Actions.LoadEvidenceBundle,
    Actions.EvaluateICP,
    Actions.IdentifyTrigger,
    Actions.DraftEmail,
    Actions.ValidateClaims,
    Actions.ValidatePersonalization,
    Actions.HandOffProposal,
    Actions.HaltAssignment
  ]

  @doc "Run phases (as AgentRun.phase)."
  def phases, do: @phases

  @doc "Signal types with a route."
  def routed_signal_types, do: Enum.map(routes(), &elem(&1, 0))

  @doc "Executables the routes select."
  def route_targets, do: Enum.map(routes(), &elem(&1, 1))

  defp routes do
    for route <- definition().routes do
      case route do
        {type, {target, _defaults}} -> {type, target}
        {type, target} when is_atom(target) -> {type, target}
        %{path: type, target: target} -> {type, target}
        %{type: type, target: target} -> {type, target}
      end
    end
  end

  @doc "The canonical AgentDefinition body (allowed actions, prompts, schemas, model policy)."
  def definition_body do
    purposes = [:evidence_extraction, :qualification, :outreach_proposal]

    %{
      "allowed_actions" =>
        Enum.map(@actions, &%{"module" => inspect(&1), "version" => &1.sdr_action_version()}),
      "flows" => [inspect(Flows.ResearchLeadFlow), inspect(Flows.PrepareOutreachFlow)],
      "prompt_templates" => Enum.map(purposes, &ref(Prompts.ref(&1))),
      "output_schemas" => Enum.map(purposes, &ref(Schemas.ref(&1))),
      "model_policy" => %{
        "provider" => "configured (fake default)",
        "max_model_calls_per_run" => 20,
        "max_tool_calls_per_run" => 60,
        "max_tokens_per_run" => 100_000,
        "tools_exposed_to_model" => []
      }
    }
  end

  @doc "Registers (or returns) the `SDRAgent` v#{@version} AgentDefinition for `tenant_id` (KRN)."
  def register(tenant_id) do
    Agents.register_definition(
      %{
        name: "SDRAgent",
        version: @version,
        module: inspect(__MODULE__),
        definition: definition_body()
      },
      actor: SdrAgent.Actor.system(:kernel, tenant_id)
    )
  end

  defp ref(%{id: id, version: version, sha256: sha256}),
    do: %{"id" => id, "version" => version, "sha256" => Base.encode16(sha256, case: :lower)}
end

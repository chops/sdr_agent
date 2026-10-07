defmodule SdrAgent.SalesFixtures do
  @moduledoc """
  Builders for Sales and Research rows (and the Agents provenance they cite),
  created through the domain APIs with the actor S2 allows for each write.
  """

  import SdrAgent.AuditCase, only: [system_actor: 2, human: 2]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Research
  alias SdrAgent.Sales

  @doc "A unique suffix for names, domains and emails."
  def unique, do: System.unique_integer([:positive])

  @doc "A resource's declared transition table `{action, from, to}`, normalised."
  def declared(resource) do
    resource.transitions()
    |> Enum.map(fn {name, from, to} -> {name, Enum.sort(from), to} end)
    |> Enum.sort()
  end

  @doc "The `{action, from, to}` of every action using the Transition change (ADR-0010)."
  def transition_actions(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.flat_map(fn action ->
      Enum.flat_map(Map.get(action, :changes, []), fn
        %{change: {SdrAgent.Audit.Changes.Transition, opts}} ->
          [{action.name, Enum.sort(opts[:from]), opts[:to]}]

        _ ->
          []
      end)
    end)
    |> Enum.sort()
  end

  @doc "Attributes of a draft ICP."
  def icp_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Mid-market logistics #{unique()}",
        description: "Fixture ICP",
        criteria: %{
          employee_count_min: 50,
          employee_count_max: 500,
          industries: ["logistics software"],
          geographies: ["US"],
          personas: ["VP Operations"],
          triggers: ["hiring SDRs"]
        }
      },
      overrides
    )
  end

  @doc "An active ICP created and activated by ADM."
  def active_icp!(tenant) do
    admin = human(:admin, tenant)
    {:ok, icp} = Sales.create_icp_definition(icp_attrs(), actor: admin)
    {:ok, icp} = Sales.update(icp, :activate, %{}, actor: admin)
    icp
  end

  @doc "A draft sequence with `steps` steps (initial email + follow-ups)."
  def sequence_with_steps!(tenant, steps \\ 2) do
    admin = human(:admin, tenant)
    {:ok, sequence} = Sales.create_sequence(%{name: "Two touch #{unique()}"}, actor: admin)

    for position <- 1..steps//1 do
      {:ok, _step} =
        Sales.add_sequence_step(
          sequence,
          %{
            position: position,
            channel: :email,
            delay_days: if(position == 1, do: 0, else: 3),
            instructions: "Touch #{position}"
          },
          actor: admin
        )
    end

    sequence
  end

  @doc "An active sequence with two steps."
  def active_sequence!(tenant) do
    {:ok, sequence} =
      Sales.update(sequence_with_steps!(tenant), :activate, %{}, actor: human(:admin, tenant))

    sequence
  end

  @doc "Attributes of a draft campaign."
  def campaign_attrs(icp, sequence, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Demo campaign #{unique()}",
        icp_definition_id: icp.id,
        sequence_id: sequence && sequence.id,
        footer_template_version: "footer/1"
      },
      overrides
    )
  end

  @doc "An active campaign over an active ICP and sequence."
  def active_campaign!(tenant) do
    admin = human(:admin, tenant)

    {:ok, campaign} =
      Sales.create_campaign(
        campaign_attrs(active_icp!(tenant), active_sequence!(tenant)),
        actor: admin
      )

    {:ok, campaign} = Sales.update(campaign, :activate, %{}, actor: admin)
    campaign
  end

  @doc "Attributes of an account under a reserved `.test` domain."
  def account_attrs(overrides \\ %{}) do
    n = unique()

    Map.merge(
      %{
        name: "Acme Freight #{n}",
        domain: "acme-freight-#{n}.test",
        industry: "logistics software",
        employee_count: 120,
        geography: "US",
        source: :manual
      },
      overrides
    )
  end

  @doc "An active account created by ADM."
  def account!(tenant, overrides \\ %{}) do
    {:ok, account} = Sales.create_account(account_attrs(overrides), actor: human(:admin, tenant))
    account
  end

  @doc "Attributes of a contact at `account`."
  def contact_attrs(account, overrides \\ %{}) do
    Map.merge(
      %{
        account_id: account.id,
        first_name: "Jo",
        last_name: "Doe",
        email: "jo.doe.#{unique()}@#{account.domain}",
        title: "VP Operations",
        persona: "VP Operations",
        timezone: "America/Denver"
      },
      overrides
    )
  end

  @doc "An active contact created by ADM (with a new account unless given)."
  def contact!(tenant, account \\ nil, overrides \\ %{}) do
    account = account || account!(tenant)

    {:ok, contact} =
      Sales.create_contact(contact_attrs(account, overrides), actor: human(:admin, tenant))

    contact
  end

  @doc "A new lead created by ADM for a new contact."
  def lead!(tenant) do
    contact = contact!(tenant)

    {:ok, lead} =
      Sales.create_lead(
        %{contact_id: contact.id, account_id: contact.account_id, source: :manual},
        actor: human(:admin, tenant)
      )

    lead
  end

  @doc "A running agent run (with its definition) and the AGT actor."
  def run!(tenant), do: AgentsFixtures.running_run(tenant)

  @doc "A deterministic phase-transition Decision by AGT about `lead`."
  def decision!(tenant, run, lead, outcome) do
    {:ok, decision} =
      Agents.record_decision(
        %{
          agent_run_id: run.id,
          kind: :phase_transition,
          mode: :deterministic,
          rule_id: "lead-phase",
          rule_version: "1",
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: lead.id,
          inputs: %{"lead" => lead.id, "to" => outcome},
          outcome: outcome,
          idempotency_key: "phase-#{lead.id}-#{outcome}-#{unique()}"
        },
        actor: system_actor(:agent_runtime, tenant)
      )

    decision
  end

  @doc """
  A lead driven by its allowed actors to `status`, one of `:new`, `:assigned`,
  `:researching`, `:qualifying` (qualified/disqualified need a Qualification).
  """
  def lead_in!(tenant, status) do
    lead = lead!(tenant)
    %{run: run} = run!(tenant)
    agent = system_actor(:agent_runtime, tenant)

    steps = [
      fn l -> Sales.update(l, :assign, %{}, actor: human(:reviewer, tenant)) end,
      fn l ->
        Sales.update(l, :start_research, %{decision_id: decision!(tenant, run, l, "research").id},
          actor: agent
        )
      end,
      fn l ->
        Sales.update(
          l,
          :start_qualifying,
          %{decision_id: decision!(tenant, run, l, "qualify").id},
          actor: agent
        )
      end
    ]

    count = Enum.find_index([:new, :assigned, :researching, :qualifying], &(&1 == status))

    steps
    |> Enum.take(count)
    |> Enum.reduce(lead, fn step, lead ->
      {:ok, next} = step.(lead)
      next
    end)
  end

  @doc "Fixture source content of a research artifact."
  def content do
    "Acme Freight is hiring three SDRs in Denver. The company has 120 employees " <>
      "and sells logistics software to mid-market shippers."
  end

  @doc "A started tool invocation for `run`."
  def tool_invocation!(tenant, run) do
    {:ok, tool} =
      Agents.start_tool_invocation(
        run,
        %{
          action_module: "SdrAgent.Actions.FetchCompanyPage",
          action_version: "1",
          input: ~s({"url":"fixture://web/acme"}),
          idempotency_key: "tool-#{unique()}"
        },
        actor: system_actor(:agent_runtime, tenant)
      )

    tool
  end

  @doc "Attributes of a research artifact for `lead` produced in `run`."
  def artifact_attrs(lead, run, tool, overrides \\ %{}) do
    Map.merge(
      %{
        lead_id: lead.id,
        agent_run_id: run.id,
        tool_invocation_id: tool.id,
        source_type: :company_website,
        provider: :fixture_web,
        source_url: "fixture://web/acme-freight",
        title: "Acme Freight — careers",
        content: content(),
        excerpt: "Acme Freight is hiring three SDRs in Denver.",
        trust_level: :high,
        freshness: :current,
        metadata: %{"fixture" => "acme"}
      },
      overrides
    )
  end

  @doc "A recorded artifact for `lead` (with its own run and tool invocation)."
  def artifact!(tenant, lead) do
    %{run: run} = run!(tenant)
    tool = tool_invocation!(tenant, run)

    {:ok, artifact} =
      Research.record_artifact(artifact_attrs(lead, run, tool),
        actor: system_actor(:agent_runtime, tenant)
      )

    %{artifact: artifact, run: run}
  end

  @doc "An evidence-quality Decision by AGT used as a claim's extraction decision."
  def extraction_decision!(tenant, run, artifact) do
    {:ok, decision} =
      Agents.record_decision(
        %{
          agent_run_id: run.id,
          kind: :evidence_quality,
          mode: :deterministic,
          rule_id: "evidence-quality",
          rule_version: "1",
          subject_resource: "SdrAgent.Research.ResearchArtifact",
          subject_id: artifact.id,
          inputs: %{"artifact" => artifact.id},
          outcome: "accepted",
          idempotency_key: "extract-#{artifact.id}-#{unique()}"
        },
        actor: system_actor(:agent_runtime, tenant)
      )

    decision
  end

  @doc "Attributes of a claim quoting `quote` from the fixture content."
  def claim_attrs(artifact, decision, quote, overrides \\ %{}) do
    start = :binary.match(content(), quote) |> elem(0)

    Map.merge(
      %{
        research_artifact_id: artifact.id,
        lead_id: artifact.lead_id,
        claim: "The company is hiring SDRs.",
        quote: quote,
        source_location: %{char_start: start, char_end: start + String.length(quote)},
        confidence: 0.9,
        quality: :accepted,
        extraction_decision_id: decision.id,
        content: content()
      },
      overrides
    )
  end

  @doc "A recorded claim on `artifact` with the given quality."
  def claim!(tenant, artifact, run, quality \\ :accepted) do
    decision = extraction_decision!(tenant, run, artifact)

    {:ok, claim} =
      Research.record_claim(
        claim_attrs(artifact, decision, "hiring three SDRs", %{quality: quality}),
        actor: system_actor(:agent_runtime, tenant)
      )

    claim
  end

  @doc """
  A completed, valid model invocation in `run` and an LLM qualification
  Decision about `lead` citing its `/qualified` output.
  """
  def qualification_decision!(tenant, run, lead) do
    agent = system_actor(:agent_runtime, tenant)

    {:ok, invocation} =
      Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("q-#{unique()}"),
        actor: agent
      )

    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: agent)

    {:ok, decision} =
      Agents.record_decision(
        %{
          agent_run_id: run.id,
          kind: :qualification,
          mode: :llm,
          model_invocation_id: invocation.id,
          output_pointer: "/qualified",
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: lead.id,
          inputs: %{"lead" => lead.id},
          outcome: "qualified"
        },
        actor: agent
      )

    decision
  end

  @doc """
  A lead qualified (or, with `qualified?: false`, disqualified) by an agent
  qualification; returns the reloaded lead and the qualification.
  """
  def qualified_lead!(tenant, qualified? \\ true) do
    lead = lead_in!(tenant, :qualifying)
    %{artifact: artifact, run: run} = artifact!(tenant, lead)
    claim = claim!(tenant, artifact, run)
    decision = qualification_decision!(tenant, run, lead)

    {:ok, qualification} =
      Research.record_qualification(
        qualification_attrs(lead, active_icp!(tenant), run, decision, [claim], %{
          qualified: qualified?
        }),
        actor: system_actor(:agent_runtime, tenant)
      )

    {:ok, lead} = Sales.get(SdrAgent.Sales.Lead, lead.id, actor: human(:admin, tenant))
    %{lead: lead, qualification: qualification, claim: claim, run: run}
  end

  @doc "Attributes of an agent qualification of `lead` against `icp`."
  def qualification_attrs(lead, icp, run, decision, claims, overrides \\ %{}) do
    Map.merge(
      %{
        lead_id: lead.id,
        icp_definition_id: icp.id,
        agent_run_id: run.id,
        decision_id: decision.id,
        qualified: true,
        score: 82,
        criteria: %{
          company_size: :pass,
          industry: :pass,
          geography: :pass,
          persona: :pass,
          trigger: :pass
        },
        confidence: 0.8,
        reason: "Fits the ICP and is hiring SDRs.",
        output_schema_version: "qualification_result/1",
        evidence_claim_ids: Enum.map(claims, & &1.id)
      },
      overrides
    )
  end
end

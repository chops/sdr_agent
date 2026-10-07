defmodule SdrAgent.SDR.GoldenPathTest do
  @moduledoc """
  Golden path (build plan steps 1–4, S7 part), hermetic on the Fake model:
  seed → `sdr.lead.assigned` → ResearchLeadFlow (artifacts + grounded
  evidence claims) → qualification (a qualified and a disqualified fixture)
  → PrepareOutreachFlow → an OutreachProposal whose claims and
  personalization cite accepted evidence, handed to S8 — and every step is
  reconstructable from Postgres alone (AgentRun, Decision, ModelInvocation,
  ToolInvocation, AuditEvent, Payload), with the audit chain intact.

  The `:external` test runs the same flow on the real Claude CLI (opus).
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.ToolInvocation
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker

  @signals ~w(sdr.lead.assigned sdr.research.requested sdr.research.completed
              sdr.qualification.requested sdr.qualification.completed
              sdr.draft.requested sdr.draft.completed)

  test "an assignment writes lead, run, operation, signal event and job in one transaction",
       ctx do
    assignment = assign!(ctx, "01")

    assert assignment.lead.status == :assigned
    assert assignment.run.status == :queued
    assert assignment.run.phase == :discover
    assert assignment.run.lead_id == assignment.lead.id
    assert assignment.run.campaign_id == ctx.campaign_id
    assert assignment.run.trigger_signal_type == "sdr.lead.assigned"
    assert assignment.run.operation_id == assignment.operation.id
    assert assignment.operation.kind == :research_lead
    assert assignment.operation.queue == :research
    assert assignment.operation.status == :enqueued
    assert assignment.operation.oban_job_id == assignment.job.id

    assert_enqueued(worker: AgentWorker, queue: :research)

    assert [event] = events_of_type(ctx.tenant, "sdr.lead.assigned")
    assert event.category == :signal
    assert event.agent_run_id == assignment.run.id
    assert event.causation_id == assignment.run.trigger_signal_id
    assert event.subject_id == assignment.lead.id
  end

  test "golden path: a qualified lead ends with an evidence-linked OutreachProposal", ctx do
    %{run: run, lead: lead, operation: operation} = assign!(ctx, "01")
    assert %{success: 1, failure: 0} = drain!()

    run = run!(ctx, run)
    assert run.status == :succeeded
    assert run.phase == :review
    assert {:ok, %{status: :succeeded}} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert {:ok, []} = Operations.list_attention(actor: ctx.admin)

    # Signals, in order, all on the ledger.
    assert signal_types(ctx.tenant, run) == @signals

    # Research artifacts, each produced by one of this run's tool invocations.
    {:ok, artifacts} =
      Research.list_records(Research.ResearchArtifact,
        filter: [lead_id: lead.id],
        actor: ctx.admin
      )

    assert Enum.sort(Enum.uniq(Enum.map(artifacts, & &1.source_type))) ==
             [:company_website, :crm_record, :news, :search_result]

    {:ok, tools} =
      SdrAgent.Audit.GuardedCall.list(ToolInvocation,
        filter: [agent_run_id: run.id],
        actor: ctx.agent
      )

    tool_ids = MapSet.new(tools, & &1.id)

    assert Enum.all?(
             artifacts,
             &(&1.agent_run_id == run.id and &1.tool_invocation_id in tool_ids)
           )

    assert Enum.all?(tools, &(&1.status == :succeeded))

    for action <-
          ~w(GetCRMHistory FetchCompanyWebsite SearchCompany ReadCompanyPage BuildEvidenceBundle
             AcceptAssignment RequestQualification ScoreLead PlanOutreach LoadEvidenceBundle
             EvaluateICP IdentifyTrigger DraftEmail ValidateClaims ValidatePersonalization
             HandOffProposal) do
      assert Enum.any?(tools, &String.ends_with?(&1.action_module, "." <> action)), action
    end

    # Grounded evidence: every claim's quote is exactly its cited span.
    {:ok, claims} =
      Research.list_records(Research.EvidenceClaim, filter: [lead_id: lead.id], actor: ctx.admin)

    accepted = Enum.filter(claims, &(&1.quality == :accepted))
    assert accepted != []
    artifacts_by_id = Map.new(artifacts, &{&1.id, &1})

    for claim <- claims do
      artifact = Map.fetch!(artifacts_by_id, claim.research_artifact_id)
      {:ok, content} = Audit.read_content(artifact.content_sha256, actor: ctx.admin)
      %{char_start: from, char_end: to} = claim.source_location
      assert String.slice(content, from, to - from) == claim.quote
    end

    # Qualification: agent source, qualified, citing accepted evidence of the lead.
    {:ok, qualification} = Research.current_qualification(lead.id, actor: ctx.admin)
    assert qualification.source == :agent
    assert qualification.qualified
    assert qualification.agent_run_id == run.id
    qualification = Ash.load!(qualification, :evidence, actor: ctx.admin)
    accepted_ids = MapSet.new(accepted, & &1.id)
    assert qualification.evidence != []
    assert Enum.all?(qualification.evidence, &(&1.evidence_claim_id in accepted_ids))

    # Lead moved through the S2 lifecycle; enrollment created.
    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    assert lead.status == :in_outreach

    {:ok, [enrollment]} =
      Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

    assert enrollment.campaign_id == ctx.campaign_id

    # The OutreachProposal handed to S8: every claim and personalization cites
    # accepted evidence of this lead and appears verbatim in the body.
    {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)
    assert proposal.lead_id == lead.id
    assert proposal.enrollment_id == enrollment.id
    assert proposal.campaign_id == ctx.campaign_id
    assert proposal.sequence_step_id
    output = proposal.output
    assert output.subject != "" and output.body != ""
    assert output.claims != [] and output.personalization != []

    for item <- output.claims ++ output.personalization do
      assert item.evidence_id in accepted_ids
      assert String.contains?(output.body, Map.get(item, :claim) || Map.get(item, :text))
    end

    # Decisions: every branch point recorded; protected kinds deterministic;
    # every llm decision cites a completed, valid invocation of this run.
    decisions = decisions!(ctx, run)
    kinds = MapSet.new(decisions, & &1.kind)

    for kind <- ~w(campaign_state_check suppression_check phase_transition budget_reservation
                   evidence_quality qualification angle draft_proposal claims_validation
                   personalization_validation enrollment)a do
      assert kind in kinds, inspect(kind)
    end

    invocations = invocations!(ctx, run)
    by_id = Map.new(invocations, &{&1.id, &1})

    for decision <- decisions do
      assert decision.agent_run_id == run.id

      if decision.kind in Decision.protected_kinds(), do: assert(decision.mode == :deterministic)

      if decision.mode == :llm do
        invocation = Map.fetch!(by_id, decision.model_invocation_id)
        assert invocation.status == :completed and invocation.validation_status == :valid
      end
    end

    assert Enum.map(invocations, & &1.purpose) ==
             [:evidence_extraction, :qualification, :outreach_proposal]

    assert Enum.all?(invocations, &(&1.provider == :fake))

    # One trace for the whole execution of the run.
    traces = MapSet.new(tools ++ invocations ++ decisions, & &1.trace_id)
    assert MapSet.size(traces) == 1

    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: ctx.aud)
  end

  test "a disqualified lead: qualification recorded, no outreach prepared", ctx do
    %{run: run, lead: lead} = assign!(ctx, "05")
    assert %{success: 1} = drain!()

    run = run!(ctx, run)
    assert run.status == :succeeded
    assert run.phase == :stop

    {:ok, qualification} = Research.current_qualification(lead.id, actor: ctx.admin)
    refute qualification.qualified
    assert qualification.criteria.company_size == :fail

    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    assert lead.status == :disqualified

    assert Enum.map(invocations!(ctx, run), & &1.purpose) == [
             :evidence_extraction,
             :qualification
           ]

    refute "sdr.draft.requested" in signal_types(ctx.tenant, run)
    assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)
  end

  @tag :external
  @tag timeout: 900_000
  test "the same flow on the real Claude CLI (opus)", ctx do
    {:ok, server} = SdrAgent.AI.ModelProvider.ClaudeCLI.start_link(timeout: 240_000)
    %{run: run, lead: lead} = assign!(ctx, "01")
    [job] = all_enqueued(worker: AgentWorker)

    assert :ok =
             AgentWorker.run(job,
               model: [
                 provider: SdrAgent.AI.ModelProvider.ClaudeCLI,
                 provider_options: [server: server]
               ]
             )

    run = run!(ctx, run)
    invocations = invocations!(ctx, run)
    assert Enum.all?(invocations, &(&1.provider == :claude_cli))
    assert Enum.all?(invocations, &(&1.model_id == "claude-opus-5-5"))
    assert run.status == :succeeded, inspect({run.status_reason, run.failure_reason})

    {:ok, qualification} = Research.current_qualification(lead.id, actor: ctx.admin)
    assert qualification.source == :agent

    if qualification.qualified do
      {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)
      assert proposal.output.claims != []
    end

    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: ctx.aud)
  end
end

defmodule SdrAgent.SDR.FirstTouchDraftTest do
  @moduledoc """
  B1-05 (map row N4; `docs/product/c4/readiness.md` C4-R5, C4-R9, C4-R13,
  test 21a; plan `claude-b1-research-draft-plan-r2.md`): the first-touch
  draft is built from the run's settings snapshot and passes a
  deterministic shape rule, bound to that exact draft, before hand-off.

    * The outreach-proposal model input carries the snapshot's offering
      profile, writing guide and research brief (from which the model
      derives the angle): the bound revisions, never ones saved after the
      run was created, or the built-in defaults by version for the guide and
      brief when none is saved. It has no booking-link slot at all, even
      when a usable link is saved (Q1).
    * On the Fake, the draft reflects the offering (a non-limit item's text),
      asks a question (the call to action is a question and appears in the
      body) and no longer carries the old fixed pitch or a proposed time.
      This hermetic check does not certify real-model compliance.
    * `ValidateDraftShape` records a deterministic `draft_shape_validation`
      Decision (rule `sdr.draft_shape`) bound to the exact `draft_proposal`
      Decision and ModelInvocation (inputs and input refs; ids only, no
      subject or body text). Reasons: `subject_not_single_line` (CR, LF or
      any other control character in the subject) and `body_contains_url`
      (`http://`, `https://` or `www.`, any letter case; this slice supplies
      no link). This is the specified syntactic check, not detection of
      every URL spelling. A rejected shape fails the run as invalid model
      output: no enrollment, no Draft, no `sdr.draft.completed`.
    * `HandOffProposal` refuses a missing, rejected or nonexistent shape
      check before any lock or write, and a persisted passed shape check
      whose provenance is wrong (another run, another draft of the same run,
      or the right draft with another invocation); a passed check with
      matching provenance reaches the enrollment gate (Codex r2 B1-R2-1).
      The wrong-provenance test asserts the kind stage first (the
      `draft_shape_validation` kind is recordable through the domain API),
      so a missing kind is told apart from a missing guard.
    * The shape check measures the draft's authoritative content — its
      ModelInvocation's stored output, read through
      `SdrAgent.Agents.released_output/2` — never the proposal map its
      caller supplies (Codex B1-R1). On a second run of a lead whose first
      run stopped at its rejected shape, the flow's steps run through their
      production actions (genuine same-run Decisions and invocation) and a
      caller-supplied map replaces the proposal after the draft step: a
      stored subject with a line break, or a stored link in the body, is
      rejected for exactly that reason and nothing is handed off although
      the map is well-shaped; a well-shaped stored draft passes and is
      handed off as stored although the map is malformed; a matching map
      passes and is handed off unchanged (control).
    * The shape check itself refuses a draft map whose Decision and
      ModelInvocation are not this run's draft of this lead (Codex B1-R1):
      the Decision must be the `:draft_proposal` (`:llm`) citing exactly
      that invocation, both of the context's run in its tenant, about the
      lead of the step. Each genuine counterexample differs from its run's
      own pair in one fact — another invocation of the same run, another
      run's coherent pair, the draft's `:angle` Decision, a
      `claims_validation` Decision, another lead, a missing row — and gets
      no passed shape check, no hand-off or write, and no draft text in the
      refusal; the genuine pair passes and is handed off (control). The
      `HandOffProposal` provenance tests above stay as the second layer.
    * The citation checks (`ValidateClaims`, `ValidatePersonalization`)
      measure the same authoritative draft, with the same association, and
      take accepted evidence from the lead's accepted EvidenceClaims
      (`Support.accepted_claims`), never the caller's list (Codex B1-R1
      neighbor scope, N1-N8; delta `claude-b1-r1-neighbor-validators-delta-r1.md`).
      A stored claim citing unaccepted evidence or absent from the body, or
      a stored draft without (or with an absent) personalization item, is
      rejected for exactly that reason and not handed off although the
      caller's map is valid. A well-cited stored draft passes and is handed
      off with its own citations although the map breaks both. Each check is
      bound to the draft's Decision and invocation (input refs), with ids,
      indexes and reason codes only. A claim the caller lists as accepted
      (this lead's non-accepted claim, another lead's claim, a missing one)
      is not accepted. A mismatched pair stops each check with no Decision.
      `HandOffProposal` refuses a passed citation check of another run,
      bound to another invocation, of the wrong kind, or unbound, each
      substituted alone beside bound checks, before its Lead lock. Each
      (case, check) runs on its own fresh run (Codex R1-R3). Rules
      unchanged: membership, verbatim presence, at least one
      personalization item; no entailment (Tier-0 review remains).

  Hermetic: Fake model provider; the recording responder
  (`SdrAgent.SettingsFixtures.RecordingBrain`) and test responders built on
  `SdrAgent.SDR.FakeBrain`; synthetic content only.

  RED: `DraftEmail` sends no offering, guide or brief; the Fake keeps its
  fixed pitch; there is no shape rule, so a malformed subject or an invented
  link is handed to review, and `HandOffProposal` gates only on the two
  citation checks.

  RED (B1-R1): `ValidateDraftShape` measures the caller's `draft.proposal`,
  so a malformed stored draft with a well-shaped map passes, bound to the
  stored records, and `HandOffProposal` hands off the stored text; a
  well-shaped stored draft with a malformed map is rejected. It also loads
  the named Decision and invocation without checking that they are this
  run's draft pair of this lead, so every mismatched pair that exists passes.
  RED (B1-R1 neighbors): `ValidateClaims` and `ValidatePersonalization`
  measure the caller's map against the caller's evidence list, load no
  record and record unbound Decisions; `HandOffProposal` accepts their
  `passed` flags.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2, revision!: 2]
  import SdrAgent.SettingsFixtures, only: [content: 2, observe: 1, save!: 3]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Actions.DraftEmail
  alias SdrAgent.SDR.Actions.EvaluateICP
  alias SdrAgent.SDR.Actions.HandOffProposal
  alias SdrAgent.SDR.Actions.IdentifyTrigger
  alias SdrAgent.SDR.Actions.LoadEvidenceBundle
  alias SdrAgent.SDR.Actions.ValidateClaims
  alias SdrAgent.SDR.Actions.ValidateDraftShape
  alias SdrAgent.SDR.Actions.ValidatePersonalization
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SettingsFixtures.RecordingBrain

  @moduletag :b1_05

  @proposal "sdr.outreach_proposal"

  # B1-R1: the subject `MultilineSubject` writes, a single-line one, and the
  # link `InventedLink` appends to the body.
  @multiline_subject "A quick question\nfor your operations team"
  @single_line_subject "A quick question for your operations team"
  @invented_link "\n\nPick a time: https://calendar.example.test/invented"

  defmodule MultilineSubject do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input),
      do: %{FakeBrain.respond(op, input) | subject: "A quick question\nfor your operations team"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule InventedLink do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      proposal = FakeBrain.respond(op, input)

      %{
        proposal
        | body: proposal.body <> "\n\nPick a time: https://calendar.example.test/invented"
      }
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule ShapeVariants do
    @moduledoc false
    # Keyed by the fixture company the draft is for (leads 02, 03, 09, 10).
    @subjects %{
      "Cobalt Dock Analytics" => "A quick question\rfor your operations team",
      "Ferngrove Fleetworks" => "A quick question\u0007for your operations team"
    }
    @links %{
      "Northgate Parcel Tech" => "HTTPS://Calendar.Example.Test/invented",
      "Quillmark Ledger Freight" => "WWW.calendar.example.test/invented"
    }

    def respond("sdr.outreach_proposal" = op, %{company: %{name: name}} = input) do
      proposal = FakeBrain.respond(op, input)

      case {Map.fetch(@subjects, name), Map.fetch(@links, name)} do
        {{:ok, subject}, _} -> %{proposal | subject: subject}
        {_, {:ok, link}} -> %{proposal | body: proposal.body <> "\n\nPick a time: " <> link}
        _other -> proposal
      end
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  # B1-R1 neighbor validators: stored citation defects (test responders).
  defmodule UnsupportedClaim do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      proposal = FakeBrain.respond(op, input)
      %{proposal | claims: Enum.map(proposal.claims, &%{&1 | evidence_id: Ecto.UUID.generate()})}
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule ClaimNotInBody do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      proposal = FakeBrain.respond(op, input)

      %{
        proposal
        | claims:
            Enum.map(proposal.claims, &%{&1 | claim: "A synthetic claim the body never states."})
      }
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule NoPersonalization do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input),
      do: %{FakeBrain.respond(op, input) | personalization: []}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule PersonalizationNotInBody do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      proposal = FakeBrain.respond(op, input)

      %{
        proposal
        | personalization:
            Enum.map(
              proposal.personalization,
              &%{&1 | text: "A synthetic detail the body never states."}
            )
      }
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule CitesEvidence do
    @moduledoc false
    # Every claim and personalization item cites the evidence id configured
    # under this module (`put_env!/2`); their text stays in the body.
    def respond("sdr.outreach_proposal" = op, input) do
      proposal = FakeBrain.respond(op, input)
      id = Application.fetch_env!(:sdr_agent, __MODULE__)

      %{
        proposal
        | claims: Enum.map(proposal.claims, &%{&1 | evidence_id: id}),
          personalization: Enum.map(proposal.personalization, &%{&1 | evidence_id: id})
      }
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  setup ctx do
    save!(:offering_profile, Fixtures.offering_profile(), ctx.admin)
    put_env!(RecordingBrain, self())
    :ok
  end

  defp assign_with!(ctx, key \\ "01", responder),
    do: assign!(ctx, key, model: [provider_options: [responder: responder]])

  # Every `{operation, input}` the recording responder saw, in call order.
  defp recorded(acc \\ []) do
    receive do
      {:fake_model_input, operation, input} -> recorded([{operation, input} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp one_input!(operation) do
    inputs = for {^operation, input} <- recorded(), do: input
    assert inputs != [], "the recording responder saw no #{operation} input"
    hd(inputs)
  end

  defp render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  defp item_triples(items),
    do:
      Enum.map(items || [], fn item ->
        {to_string(Map.get(item, :id)), to_string(Map.get(item, :kind)), Map.get(item, :text)}
      end)

  defp shape_decision(ctx, run) do
    shapes = ctx |> decisions!(run) |> Enum.filter(&(&1.kind == :draft_shape_validation))

    assert length(shapes) == 1,
           "B1-05: the run recorded #{length(shapes)} draft_shape_validation Decisions, expected one"

    hd(shapes)
  end

  defp nothing_handed_off!(ctx, run, lead) do
    refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
    assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)

    {:ok, enrollments} =
      Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

    assert enrollments == [], "B1-05: the lead was enrolled"

    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    assert drafts == [], "B1-05: a Draft was created"
  end

  defp assert_rejected!(ctx, run, lead, reason) do
    run = run!(ctx, run)

    assert run.status == :failed,
           "B1-05: a draft failing the shape rule (#{reason}) was handed to review " <>
             "(run #{run.status})"

    assert run.status_reason == :invalid_model_output

    shape = shape_decision(ctx, run)
    assert shape.mode == :deterministic
    assert shape.rule_id == "sdr.draft_shape"
    assert shape.outcome == "rejected"

    assert reason in List.wrap(shape.outcome_detail["reasons"]),
           "B1-05: the rejection does not name #{reason}: #{inspect(shape.outcome_detail)}"

    nothing_handed_off!(ctx, run, lead)
  end

  defp running_run!(ctx, lead) do
    {:ok, definition} = SDRAgent.register(ctx.tenant.id)

    attrs =
      definition
      |> AgentsFixtures.run_attrs()
      |> Map.merge(%{lead_id: lead.id, campaign_id: ctx.campaign_id})

    {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    run
  end

  defp context(ctx, run, label) do
    %Context{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      signal_id: "sig-b1-gate-#{label}",
      agent_state: %{phase: :validate, campaign_id: ctx.campaign_id}
    }
  end

  defp lead_status!(ctx, lead) do
    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    lead.status
  end

  # A genuine draft_proposal Decision and its completed ModelInvocation on
  # `run`, through domain actions only: `%{decision, invocation}`.
  defp genuine_draft!(ctx, run, lead, key) do
    attrs = key |> AgentsFixtures.model_attrs() |> Map.put(:purpose, :outreach_proposal)
    {:ok, run} = Agents.get_run(run.id, actor: ctx.agent)
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: ctx.agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: ctx.agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: ctx.agent)

    {:ok, decision} =
      Context.decide(
        context(ctx, run, key),
        %{
          kind: :draft_proposal,
          mode: :llm,
          subject_id: lead.id,
          model_invocation_id: invocation.id,
          output_pointer: "",
          inputs: %{"evidence_ids" => []},
          outcome: "proposed",
          rationale: "fixture draft"
        },
        key
      )

    %{decision: decision, invocation: invocation}
  end

  # A passed draft_shape_validation Decision recorded on `run` that binds
  # `draft` (its inputs and input refs), through `Context.decide/4` (the
  # domain API). Asserts the kind stage: before the kind exists this fails
  # here, distinguishable from the later guard-stage assertions.
  defp shape_on!(ctx, run, lead, draft, point) do
    result =
      Context.decide(
        context(ctx, run, point),
        %{
          kind: :draft_shape_validation,
          mode: :deterministic,
          rule_id: "sdr.draft_shape",
          rule_version: "1",
          subject_id: lead.id,
          inputs: %{
            "draft_proposal_decision_id" => draft.decision.id,
            "model_invocation_id" => draft.invocation.id
          },
          outcome: "passed",
          outcome_detail: %{"reasons" => []}
        },
        "shape-#{point}",
        [draft.decision, draft.invocation]
      )

    assert match?({:ok, %{kind: :draft_shape_validation, outcome: "passed"}}, result),
           "B1-05 kind stage: a passed draft_shape_validation Decision cannot be recorded " <>
             "through the domain API (#{short(result)}); the guard stage was not reached"

    {:ok, shape} = result
    shape
  end

  # HandOffProposal v3 (B1-R1) binds the two citation checks as well, so each
  # case carries passed claims and personalization checks of its own run,
  # bound to exactly its draft: every case is accepted or refused on its
  # shape check alone.
  defp gate_params(ctx, run, lead, draft, shape, label),
    do: %{
      lead_id: lead.id,
      draft: %{
        decision_id: draft.decision.id,
        model_invocation_id: draft.invocation.id,
        proposal: %{}
      },
      claims_check: bound_citation!(ctx, run, lead, draft, :claims_validation, label),
      personalization_check:
        bound_citation!(ctx, run, lead, draft, :personalization_validation, label),
      shape_check: %{passed: true, decision_id: shape.id},
      plan: %{campaign_id: ctx.campaign_id, step: %{id: Ecto.UUID.generate()}}
    }

  defp bound_citation!(ctx, run, lead, draft, kind, label) do
    rule =
      if kind == :claims_validation,
        do: "sdr.claims_cite_evidence",
        else: "sdr.personalization_cites_evidence"

    {:ok, check} =
      Context.decide(
        context(ctx, run, label),
        %{
          kind: kind,
          mode: :deterministic,
          rule_id: rule,
          rule_version: "1",
          subject_id: lead.id,
          inputs: %{
            "draft_proposal_decision_id" => draft.decision.id,
            "model_invocation_id" => draft.invocation.id,
            "accepted_evidence_ids" => []
          },
          outcome: "passed",
          outcome_detail: %{"rejected" => [], "too_few" => false}
        },
        "citation-#{label}",
        [draft.decision, draft.invocation]
      )

    %{passed: true, decision_id: check.id}
  end

  defp control?(text), do: Regex.match?(~r/\p{Cc}/u, text)

  defp link?(text), do: Regex.match?(~r/https?:\/\/|www\./iu, text)

  # A fixture step's `{:ok, output}`; anything else fails the fixture stage.
  defp step!(label, result) do
    assert match?({:ok, %{}}, result),
           "B1-R1 fixture stage: the #{label} step returned #{short(result)}"

    elem(result, 1)
  end

  # Lead 01, qualified with accepted evidence by a genuine assignment run
  # that then stopped at its rejected multi-line subject: nothing was
  # enrolled or handed off, so a second run of the lead can reach a real
  # enrollment.
  defp qualified_lead!(ctx) do
    %{run: first, lead: lead} = assign_with!(ctx, MultilineSubject)
    drain!()
    first = run!(ctx, first)

    assert {first.status, first.status_reason} == {:failed, :invalid_model_output},
           "B1-R1 fixture stage: the first run was not stopped at its rejected shape " <>
             "(#{first.status}, #{first.status_reason})"

    assert lead_status!(ctx, lead) == :qualified,
           "B1-R1 fixture stage: the lead is not qualified after the first run"

    lead
  end

  # The draft's authoritative content: its ModelInvocation's stored output,
  # read through the released-output read and parsed by the proposal schema.
  defp stored_output!(ctx, draft) do
    result =
      with {:ok, released} <-
             Agents.released_output(draft.model_invocation_id, actor: ctx.agent),
           do: Zoi.parse(Schemas.outreach_proposal(), released)

    assert match?({:ok, %{subject: _, body: _}}, result),
           "B1-R1 fixture stage: the draft's stored output is unreadable: #{short(result)}"

    elem(result, 1)
  end

  # PrepareOutreachFlow's steps on a new running run of `lead`, each through
  # its production action, the model answering through `responder`: genuine
  # same-run draft_proposal Decision, ModelInvocation and checks. After the
  # draft step, `supply` maps the draft step's proposal to the proposal of
  # the draft map the later steps receive (the caller-supplied map); the
  # hand-off runs when the shape step returns a check, as in the flow.
  defp drive!(ctx, lead, responder, supply) do
    run = running_run!(ctx, lead)
    sdr = %{context(ctx, run, "b1-r1") | model: [provider_options: [responder: responder]]}

    bundle = step!("bundle", LoadEvidenceBundle.perform(%{lead_id: lead.id}, sdr))

    plan =
      step!(
        "icp",
        EvaluateICP.perform(%{lead_id: lead.id, qualification: bundle.qualification}, sdr)
      )

    %{triggers: triggers} =
      step!("trigger", IdentifyTrigger.perform(%{claims: bundle.claims, icp: plan.icp}, sdr))

    draft =
      step!(
        "draft",
        DraftEmail.perform(
          %{lead_id: lead.id, claims: bundle.claims, triggers: triggers, plan: plan},
          sdr
        )
      )

    stored = stored_output!(ctx, draft)

    assert {stored.subject, stored.body} == {draft.proposal.subject, draft.proposal.body},
           "B1-R1 fixture stage: the draft step's proposal is not its stored output"

    supplied = %{draft | proposal: supply.(draft.proposal)}
    checked = %{lead_id: lead.id, draft: supplied, claims: bundle.claims}
    claims_check = step!("claims", ValidateClaims.perform(checked, sdr))

    personalization_check =
      step!("personalization", ValidatePersonalization.perform(checked, sdr))

    assert claims_check.passed and personalization_check.passed,
           "B1-R1 fixture stage: the draft's citation checks did not pass"

    shape =
      observe(fn -> ValidateDraftShape.perform(%{lead_id: lead.id, draft: supplied}, sdr) end)

    handoff =
      case shape do
        {:ok, %{} = shape_check} ->
          observe(fn ->
            HandOffProposal.perform(
              %{
                lead_id: lead.id,
                draft: supplied,
                claims_check: claims_check,
                personalization_check: personalization_check,
                shape_check: shape_check,
                plan: plan
              },
              sdr
            )
          end)

        _stopped ->
          :not_reached
      end

    %{
      run: run,
      draft: draft,
      stored: stored,
      supplied: supplied.proposal,
      shape: shape,
      handoff: handoff
    }
  end

  # What was handed to review for `lead`: each Draft's current revision.
  defp handed_off(ctx, lead) do
    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    for draft <- drafts do
      revision = revision!(ctx, draft.current_revision_id)
      %{subject: revision.subject, link_in_body: link?(revision.body_text)}
    end
  end

  # The run's one shape check is the returned one, bound to exactly the
  # draft's Decision and invocation, with ids only: no line of the stored or
  # the supplied subject or body in its inputs, outcome detail or rationale.
  defp recorded_shape!(ctx, %{shape: {:ok, %{decision_id: id}}} = driven) do
    shape = shape_decision(ctx, driven.run)
    assert shape.id == id
    assert {shape.mode, shape.rule_id} == {:deterministic, "sdr.draft_shape"}

    assert MapSet.new(shape.input_refs, &{&1.resource, &1.id}) ==
             MapSet.new([
               {"SdrAgent.Agents.Decision", driven.draft.decision_id},
               {"SdrAgent.Agents.ModelInvocation", driven.draft.model_invocation_id}
             ]),
           "B1-R1: the shape check is not bound to exactly the draft's Decision and invocation"

    {:ok, inputs} = Audit.read_content(shape.inputs_sha256, actor: ctx.admin)
    recorded = [inputs, render(shape.outcome_detail), shape.rationale || ""]

    for proposal <- [driven.stored, driven.supplied],
        text <- [proposal.subject, proposal.body],
        line <- String.split(text, ~r/\p{Cc}+/u, trim: true),
        String.length(line) >= 12,
        field <- recorded do
      refute String.contains?(field, line),
             "B1-R1: the shape check records draft text: #{short(line)}"
    end

    shape
  end

  # Rejected for exactly the stored draft's `reason`, and nothing handed off.
  defp assert_stored_rejected!(ctx, driven, lead, reason) do
    shape = recorded_shape!(ctx, driven)
    assert shape.outcome == "rejected"

    assert List.wrap(shape.outcome_detail["reasons"]) == [reason],
           "B1-R1: the rejection does not name exactly the stored draft's #{reason}: " <>
             inspect(shape.outcome_detail)

    assert driven.handoff == {:error, {:halt, :invalid_model_output}},
           "B1-R1: the hand-off of a rejected draft was not refused: #{short(driven.handoff)}"

    failed = run!(ctx, driven.run)
    assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}
    nothing_handed_off!(ctx, driven.run, lead)
    assert lead_status!(ctx, lead) == :qualified, "B1-R1: a rejected draft moved the lead"
  end

  # Passed, and the stored output (never the supplied map) handed to review.
  defp assert_stored_handed_off!(ctx, driven, lead) do
    shape = recorded_shape!(ctx, driven)
    assert shape.outcome == "passed"
    assert List.wrap(shape.outcome_detail["reasons"]) == []

    assert match?({:ok, %{phase: :review}}, driven.handoff),
           "B1-R1: the well-shaped stored draft was not handed off: #{short(driven.handoff)}"

    assert "sdr.draft.completed" in signal_types(ctx.tenant, driven.run)

    {:ok, proposal} = SDR.proposal(driven.run.id, actor: ctx.agent)

    assert {proposal.decision_id, proposal.model_invocation_id} ==
             {driven.draft.decision_id, driven.draft.model_invocation_id}

    assert {proposal.output.subject, proposal.output.body} ==
             {driven.stored.subject, driven.stored.body}

    {:ok, [handed]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    revision = revision!(ctx, handed.current_revision_id)

    assert {revision.subject, revision.body_text} == {driven.stored.subject, driven.stored.body},
           "B1-R1: the Draft handed to review is not the draft's stored output"

    refute control?(revision.subject), "B1-R1: a subject with a control character was handed off"
    refute link?(revision.body_text), "B1-R1: a body with a link was handed off"
    assert lead_status!(ctx, lead) == :in_outreach
  end

  # A genuine draft on a new running run of `lead`: the flow's steps through
  # the two citation checks, each through its production action, with the
  # model answering through `responder`.
  defp drafted!(ctx, lead, responder, label) do
    run = running_run!(ctx, lead)
    sdr = %{context(ctx, run, label) | model: [provider_options: [responder: responder]]}
    bundle = step!("bundle", LoadEvidenceBundle.perform(%{lead_id: lead.id}, sdr))

    plan =
      step!(
        "icp",
        EvaluateICP.perform(%{lead_id: lead.id, qualification: bundle.qualification}, sdr)
      )

    %{triggers: triggers} =
      step!("trigger", IdentifyTrigger.perform(%{claims: bundle.claims, icp: plan.icp}, sdr))

    draft =
      step!(
        "draft",
        DraftEmail.perform(
          %{lead_id: lead.id, claims: bundle.claims, triggers: triggers, plan: plan},
          sdr
        )
      )

    checked = %{lead_id: lead.id, draft: draft, claims: bundle.claims}
    claims_check = step!("claims", ValidateClaims.perform(checked, sdr))

    personalization_check =
      step!("personalization", ValidatePersonalization.perform(checked, sdr))

    %{
      run: run,
      sdr: sdr,
      plan: plan,
      draft: draft,
      stored: stored_output!(ctx, draft),
      claims_check: claims_check,
      personalization_check: personalization_check
    }
  end

  # The association facts of a draft map's Decision and invocation, read as
  # the agent runtime in its tenant.
  defp facts!(ctx, pair) do
    {:ok, decision} = Agents.get_decision(pair.decision_id, actor: ctx.agent)
    {:ok, invocation} = Agents.get_model_invocation(pair.model_invocation_id, actor: ctx.agent)

    %{
      kind: decision.kind,
      mode: decision.mode,
      cites_invocation: decision.model_invocation_id == invocation.id,
      decision_run: decision.agent_run_id,
      invocation_run: invocation.agent_run_id,
      lead: decision.subject_id
    }
  end

  # The facts of a genuine draft pair of `run` about `lead`.
  defp coherent(run, lead),
    do: %{
      kind: :draft_proposal,
      mode: :llm,
      cites_invocation: true,
      decision_run: run.id,
      invocation_run: run.id,
      lead: lead.id
    }

  # The shape step for the draft map `pair` on `drafted`'s run, then the
  # hand-off as the flow would run it (only when the step returns a check).
  defp shape_then_hand_off(drafted, lead_id, pair) do
    shape =
      observe(fn ->
        ValidateDraftShape.perform(%{lead_id: lead_id, draft: pair}, drafted.sdr)
      end)

    handoff =
      case shape do
        {:ok, %{} = check} ->
          observe(fn ->
            HandOffProposal.perform(
              %{
                lead_id: lead_id,
                draft: pair,
                claims_check: drafted.claims_check,
                personalization_check: drafted.personalization_check,
                shape_check: check,
                plan: drafted.plan
              },
              drafted.sdr
            )
          end)

        _stopped ->
          :not_reached
      end

    {shape, handoff}
  end

  # Fail-closed for a draft map whose pair is not this run's draft of this
  # lead: no passed shape check (a refusal or a check that did not pass), no
  # hand-off, enrollment, lead transition, signal or Draft, and no line of
  # the stored draft text in the step's or the hand-off's result or in the
  # run's failure reason.
  defp assert_pair_refused!(ctx, drafted, lead, label, {shape, handoff}) do
    refute match?({:ok, %{passed: true}}, shape),
           "B1-R1: ValidateDraftShape passed #{label}: #{short(shape)}; the hand-off then " <>
             "returned #{short(handoff)}"

    refute Enum.any?(
             decisions!(ctx, drafted.run),
             &(&1.kind == :draft_shape_validation and &1.outcome == "passed")
           ),
           "B1-R1: a passed shape check was recorded for #{label}"

    refute match?({:ok, %{phase: :review}}, handoff), "B1-R1: #{label} was handed off"
    nothing_handed_off!(ctx, drafted.run, lead)
    assert lead_status!(ctx, lead) == :qualified, "B1-R1: #{label} moved the lead"

    echoed = [render(shape), render(handoff), run!(ctx, drafted.run).failure_reason || ""]

    for text <- [drafted.stored.subject, drafted.stored.body],
        line <- String.split(text, ~r/\p{Cc}+/u, trim: true),
        String.length(line) >= 12,
        field <- echoed do
      refute String.contains?(field, line),
             "B1-R1: the refusal of #{label} echoes draft text: #{short(line)}"
    end
  end

  # A genuine draft on a new running run of `lead`: the flow's steps up to
  # the draft step, each through its production action (no check yet).
  defp draft_only!(ctx, lead, responder, label) do
    run = running_run!(ctx, lead)
    sdr = %{context(ctx, run, label) | model: [provider_options: [responder: responder]]}
    bundle = step!("bundle", LoadEvidenceBundle.perform(%{lead_id: lead.id}, sdr))

    plan =
      step!(
        "icp",
        EvaluateICP.perform(%{lead_id: lead.id, qualification: bundle.qualification}, sdr)
      )

    %{triggers: triggers} =
      step!("trigger", IdentifyTrigger.perform(%{claims: bundle.claims, icp: plan.icp}, sdr))

    draft =
      step!(
        "draft",
        DraftEmail.perform(
          %{lead_id: lead.id, claims: bundle.claims, triggers: triggers, plan: plan},
          sdr
        )
      )

    %{
      run: run,
      sdr: sdr,
      bundle: bundle,
      plan: plan,
      draft: draft,
      stored: stored_output!(ctx, draft)
    }
  end

  # The flow's steps after the draft step on `d`'s run: both citation checks
  # with the draft map `supplied` and the evidence list `evidence`, the shape
  # check, then the hand-off when all three return a check (as the flow).
  defp check_then_hand_off(d, lead_id, supplied, evidence) do
    checked = %{lead_id: lead_id, draft: supplied, claims: evidence}
    claims = observe(fn -> ValidateClaims.perform(checked, d.sdr) end)
    personalization = observe(fn -> ValidatePersonalization.perform(checked, d.sdr) end)

    shape =
      observe(fn -> ValidateDraftShape.perform(%{lead_id: lead_id, draft: supplied}, d.sdr) end)

    handoff =
      case {claims, personalization, shape} do
        {{:ok, %{} = claims_check}, {:ok, %{} = personalization_check}, {:ok, %{} = shape_check}} ->
          observe(fn ->
            HandOffProposal.perform(
              %{
                lead_id: lead_id,
                draft: supplied,
                claims_check: claims_check,
                personalization_check: personalization_check,
                shape_check: shape_check,
                plan: d.plan
              },
              d.sdr
            )
          end)

        _stopped ->
          :not_reached
      end

    %{claims: claims, personalization: personalization, shape: shape, handoff: handoff}
  end

  # The ids of the lead's accepted evidence claims (the domain read).
  defp accepted_ids!(ctx, lead) do
    {:ok, claims} =
      Research.list_records(Research.EvidenceClaim,
        filter: [lead_id: lead.id, quality: :accepted],
        actor: ctx.admin
      )

    Enum.map(claims, & &1.id)
  end

  # Every text a proposal carries: subject, body, claims, personalization.
  defp texts(proposal),
    do:
      [proposal.subject, proposal.body] ++
        Enum.map(proposal.claims, & &1.claim) ++ Enum.map(proposal.personalization, & &1.text)

  defp citation_decision!(ctx, run, kind) do
    found = ctx |> decisions!(run) |> Enum.filter(&(&1.kind == kind))

    assert length(found) == 1,
           "B1-R1: the run recorded #{length(found)} #{kind} Decisions, expected one"

    hd(found)
  end

  # A citation check bound to exactly the draft's Decision and invocation,
  # its accepted set the lead's accepted evidence (never the caller's list),
  # with ids, indexes and reason codes only: no line of `texts`.
  defp assert_citation_bound!(ctx, decision, d, lead, texts) do
    assert MapSet.new(decision.input_refs, &{&1.resource, &1.id}) ==
             MapSet.new([
               {"SdrAgent.Agents.Decision", d.draft.decision_id},
               {"SdrAgent.Agents.ModelInvocation", d.draft.model_invocation_id}
             ]),
           "B1-R1: the #{decision.kind} check is not bound to exactly the draft's Decision " <>
             "and invocation: #{short(decision.input_refs)}"

    {:ok, inputs} = Audit.read_content(decision.inputs_sha256, actor: ctx.admin)

    assert Enum.sort(JSON.decode!(inputs)["accepted_evidence_ids"]) ==
             Enum.sort(accepted_ids!(ctx, lead)),
           "B1-R1: the #{decision.kind} check's accepted set is not the lead's accepted evidence"

    recorded = [inputs, render(decision.outcome_detail), decision.rationale || ""]

    for text <- texts,
        line <- String.split(text, ~r/\p{Cc}+/u, trim: true),
        String.length(line) >= 12,
        field <- recorded do
      refute String.contains?(field, line),
             "B1-R1: the #{decision.kind} check records draft text: #{short(line)}"
    end
  end

  # The `kind` check rejected the stored draft for `expected` (a reason code
  # of item 0, or `:too_few`), bound and private; nothing handed off.
  defp assert_stored_citations_rejected!(ctx, d, lead, supplied, checks, kind, expected) do
    decision = citation_decision!(ctx, d.run, kind)
    key = if kind == :claims_validation, do: :claims, else: :personalization
    id = decision.id
    assert match?({:ok, %{passed: false, decision_id: ^id}}, Map.fetch!(checks, key))
    assert {decision.mode, decision.outcome} == {:deterministic, "rejected"}

    case expected do
      :too_few ->
        assert decision.outcome_detail["too_few"] == true

      reason ->
        assert [%{"index" => 0, "reasons" => reasons} | _] = decision.outcome_detail["rejected"]
        assert reason in reasons, "B1-R1: the rejection does not name #{reason}"
    end

    assert_citation_bound!(ctx, decision, d, lead, texts(d.stored) ++ texts(supplied))

    assert checks.handoff == {:error, {:halt, :invalid_model_output}},
           "B1-R1: the hand-off of a rejected draft was not refused: #{short(checks.handoff)}"

    failed = run!(ctx, d.run)
    assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}
    nothing_handed_off!(ctx, d.run, lead)
    assert lead_status!(ctx, lead) == :qualified, "B1-R1: a rejected draft moved the lead"
  end

  # Both citation checks passed on the stored draft, bound and private, and
  # the stored draft (with its own citations) handed off.
  defp assert_stored_citations_handed_off!(ctx, d, lead, supplied, checks) do
    for kind <- [:claims_validation, :personalization_validation] do
      decision = citation_decision!(ctx, d.run, kind)
      assert {decision.mode, decision.outcome} == {:deterministic, "passed"}
      assert_citation_bound!(ctx, decision, d, lead, texts(d.stored) ++ texts(supplied))
    end

    assert_stored_handed_off!(
      ctx,
      %{
        run: d.run,
        draft: d.draft,
        stored: d.stored,
        supplied: supplied,
        shape: checks.shape,
        handoff: checks.handoff
      },
      lead
    )

    {:ok, proposal} = SDR.proposal(d.run.id, actor: ctx.agent)

    assert {proposal.output.claims, proposal.output.personalization} ==
             {d.stored.claims, d.stored.personalization},
           "B1-R1: the hand-off does not carry the stored draft's citations"
  end

  # The genuine shape check of `d`'s own draft (passes before and after GREEN).
  defp genuine_shape!(d, lead) do
    shape = ValidateDraftShape.perform(%{lead_id: lead.id, draft: d.draft}, d.sdr)

    assert match?({:ok, %{passed: true}}, shape),
           "B1-R1 fixture stage: the genuine draft's shape check did not pass: #{short(shape)}"

    elem(shape, 1)
  end

  # A passed citation check of `kind` recorded on `d`'s run through the
  # domain API, naming `pair` in its inputs, with `refs` as its input refs.
  # Asserts the kind stage, so a refusal to record is told apart from the
  # hand-off guard.
  defp passed_check!(d, lead, kind, pair, refs, point) do
    rule =
      if kind == :claims_validation,
        do: "sdr.claims_cite_evidence",
        else: "sdr.personalization_cites_evidence"

    result =
      Context.decide(
        d.sdr,
        %{
          kind: kind,
          mode: :deterministic,
          rule_id: rule,
          rule_version: "1",
          subject_id: lead.id,
          inputs: %{
            "draft_proposal_decision_id" => pair.decision_id,
            "model_invocation_id" => pair.model_invocation_id,
            "accepted_evidence_ids" => Enum.map(d.bundle.claims, & &1.id)
          },
          outcome: "passed",
          outcome_detail: %{"rejected" => [], "too_few" => false}
        },
        point,
        refs
      )

    assert match?({:ok, %{outcome: "passed"}}, result),
           "B1-R1 kind stage: a passed #{kind} Decision cannot be recorded through the " <>
             "domain API (#{short(result)}); the guard stage was not reached"

    {:ok, decision} = result
    %{passed: true, decision_id: decision.id}
  end

  describe "the draft input" do
    test "carries the snapshot's offering, guide and brief, and no booking-link slot", ctx do
      guide = "Write two short paragraphs and ask one question (guide revision one)."
      brief = "Look for synthetic dock scheduling needs (brief revision one)."
      save!(:writing_guide, %{text: guide}, ctx.admin)
      save!(:research_brief, content(:research_brief, %{guidance: brief}), ctx.admin)
      # A usable link: still never part of this slice's draft (Q1).
      save!(:booking_link, %{url: "https://book.example.test/demo/intro"}, ctx.admin)

      %{run: run} = assign_with!(ctx, RecordingBrain)

      save!(:writing_guide, %{text: "A later guide (guide revision two)."}, ctx.admin)

      save!(
        :research_brief,
        content(:research_brief, %{guidance: "A later brief (brief revision two)."}),
        ctx.admin
      )

      save!(
        :offering_profile,
        Map.put(Fixtures.offering_profile(), :name, "A later offering (offering revision two)"),
        ctx.admin
      )

      drain!()

      input = one_input!(@proposal)
      expected = Fixtures.offering_profile()

      offering = Map.get(input, :offering)
      assert offering, "B1-05: the outreach-proposal input carries no offering"
      assert Map.get(offering, :name) == expected.name
      assert Map.get(offering, :summary) == expected.summary
      assert Map.get(offering, :audience) == expected.audience
      assert item_triples(Map.get(offering, :items)) == item_triples(expected.items)

      writing_guide = Map.get(input, :writing_guide)
      assert writing_guide, "B1-05: the outreach-proposal input carries no writing_guide"
      assert Map.get(writing_guide, :text) == guide

      research_brief = Map.get(input, :research_brief)
      assert research_brief, "B1-05: the outreach-proposal input carries no research_brief"
      assert Map.get(research_brief, :guidance) == brief

      rendered = render(input)

      refute rendered =~ "revision two",
             "B1-05: settings saved after the run was created reached its draft"

      refute Map.has_key?(input, :booking_link), "B1-05: the draft input has a booking-link slot"
      refute rendered =~ "book.example.test", "B1-05: a booking link reached the draft input"
      assert run!(ctx, run).status == :succeeded
    end

    test "without a saved guide or brief it carries the built-in defaults", ctx do
      assign_with!(ctx, RecordingBrain)
      drain!()

      input = one_input!(@proposal)
      guide = CodeDefaults.current(:writing_guide)
      brief = CodeDefaults.current(:research_brief)

      writing_guide = Map.get(input, :writing_guide)
      assert writing_guide, "B1-05: the outreach-proposal input carries no writing_guide"

      assert Map.get(writing_guide, :text) == guide.content.text,
             "B1-05: the built-in default guide version #{guide.version} was not used"

      research_brief = Map.get(input, :research_brief)
      assert research_brief, "B1-05: the outreach-proposal input carries no research_brief"
      assert Map.get(research_brief, :guidance) == brief.content.guidance
    end
  end

  describe "the draft output (Fake)" do
    test "reflects a distinct offering, asks a question and drops the fixed pitch", ctx do
      feature = "Books synthetic dock slots in one shared view."
      limit = "Does not file synthetic customs paperwork."

      save!(
        :offering_profile,
        %{
          name: "Example Dock Slot Planner",
          summary: "A synthetic dock-slot booking product used only in tests.",
          audience: "Yard teams at synthetic logistics companies.",
          items: [
            %{id: "dock_slots", kind: :feature, text: feature},
            %{id: "no_customs", kind: :limit, text: limit}
          ]
        },
        ctx.admin
      )

      %{run: run, lead: lead} = assign!(ctx, "01")
      drain!()

      {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)
      output = proposal.output

      assert String.contains?(output.body, feature),
             "B1-05: the draft does not use the offering's item: #{short(output.body)}"

      refute String.contains?(output.body, limit), "B1-05: the draft pitches a limit item"
      refute output.body =~ "Demo SDR helps revenue teams", "B1-05: the old fixed pitch remains"
      refute output.subject =~ "ramping your new SDRs", "B1-05: the old fixed subject remains"

      refute output.body =~ ~r/next week|20-minute/i,
             "B1-05: the draft still proposes a meeting time"

      assert String.ends_with?(String.trim(output.cta), "?"),
             "B1-05: the call to action is not a question: #{short(output.cta)}"

      assert String.contains?(output.body, output.cta), "B1-05: the body does not ask it"

      {:ok, [draft]} =
        Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

      revision = revision!(ctx, draft.current_revision_id)
      assert {revision.subject, revision.body_text} == {output.subject, output.body}
    end
  end

  describe "the shape rule" do
    test "a well-shaped draft records a passed check bound to its exact draft and invocation",
         ctx do
      %{run: run} = assign!(ctx, "01")
      drain!()

      run = run!(ctx, run)
      assert run.status == :succeeded

      shape = shape_decision(ctx, run)
      assert shape.mode == :deterministic
      assert shape.rule_id == "sdr.draft_shape"
      assert shape.outcome == "passed"
      assert shape.agent_run_id == run.id

      {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)

      assert Enum.any?(
               shape.input_refs,
               &(&1.resource == "SdrAgent.Agents.Decision" and &1.id == proposal.decision_id)
             ),
             "B1-05: the shape check does not cite the exact draft_proposal Decision"

      assert Enum.any?(
               shape.input_refs,
               &(&1.resource == "SdrAgent.Agents.ModelInvocation" and
                   &1.id == proposal.model_invocation_id)
             ),
             "B1-05: the shape check does not cite the draft's ModelInvocation"

      {:ok, inputs} = Audit.read_content(shape.inputs_sha256, actor: ctx.admin)
      decoded = JSON.decode!(inputs)
      assert decoded["draft_proposal_decision_id"] == proposal.decision_id
      assert decoded["model_invocation_id"] == proposal.model_invocation_id

      # Ids only: no subject or body text in the check's inputs, outcome or rationale.
      for text <- [proposal.output.subject, proposal.output.body] do
        refute inputs =~ text
        refute render(shape.outcome_detail) =~ text
        refute (shape.rationale || "") =~ text
      end

      refute proposal.output.subject =~ ~r/[\x00-\x1F\x7F]/
      refute proposal.output.body =~ ~r/https?:\/\/|www\./i
    end

    test "a multi-line subject is rejected deterministically and not handed off", ctx do
      %{run: run, lead: lead} = assign_with!(ctx, MultilineSubject)
      drain!()
      assert_rejected!(ctx, run, lead, "subject_not_single_line")
    end

    test "a carriage return or another control character in the subject is rejected", ctx do
      for key <- ["02", "03"] do
        %{run: run, lead: lead} = assign_with!(ctx, key, ShapeVariants)
        drain!()
        assert_rejected!(ctx, run, lead, "subject_not_single_line")
      end
    end

    test "a body with a link the run did not supply is rejected and not handed off", ctx do
      %{run: run, lead: lead} = assign_with!(ctx, InventedLink)
      drain!()
      assert_rejected!(ctx, run, lead, "body_contains_url")
    end

    test "upper-case HTTPS and WWW links are rejected as well", ctx do
      for key <- ["09", "10"] do
        %{run: run, lead: lead} = assign_with!(ctx, key, ShapeVariants)
        drain!()
        assert_rejected!(ctx, run, lead, "body_contains_url")
      end
    end
  end

  describe "the hand-off gate" do
    test "HandOffProposal refuses a missing, rejected or unbound shape check before any write",
         ctx do
      lead = fixture_lead!(ctx, "01")

      params = %{
        lead_id: lead.id,
        draft: %{
          decision_id: Ecto.UUID.generate(),
          model_invocation_id: Ecto.UUID.generate(),
          proposal: %{}
        },
        claims_check: %{passed: true, decision_id: Ecto.UUID.generate()},
        personalization_check: %{passed: true, decision_id: Ecto.UUID.generate()},
        plan: %{campaign_id: ctx.campaign_id, step: %{id: Ecto.UUID.generate()}}
      }

      for {label, shape_check} <- [
            missing: nil,
            rejected: %{passed: false, decision_id: Ecto.UUID.generate()},
            # A Decision id that names no record; persisted passed checks
            # with wrong provenance are the next test.
            nonexistent: %{passed: true, decision_id: Ecto.UUID.generate()}
          ] do
        run = running_run!(ctx, lead)
        attempt = if shape_check, do: Map.put(params, :shape_check, shape_check), else: params

        result = observe(fn -> HandOffProposal.perform(attempt, context(ctx, run, label)) end)

        assert result == {:error, {:halt, :invalid_model_output}},
               "B1-05: a #{label} shape check was not refused: #{short(result)}"

        failed = run!(ctx, run)
        assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}

        refute Enum.any?(decisions!(ctx, run), &(&1.kind == :enrollment)),
               "B1-05: a #{label} shape check reached the enrollment gate"

        refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
      end

      {:ok, enrollments} =
        Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

      assert enrollments == []
    end

    test "HandOffProposal accepts a passed shape check only for its own run, draft and invocation",
         ctx do
      lead = fixture_lead!(ctx, "01")
      status = lead_status!(ctx, lead)

      # Genuine fixtures through domain actions: each case gets its own
      # running run with real draft_proposal Decisions and invocations.
      matching = running_run!(ctx, lead)
      matching_a = genuine_draft!(ctx, matching, lead, "matching-a")

      other_run = running_run!(ctx, lead)
      other_run_a = genuine_draft!(ctx, other_run, lead, "other-run-a")
      holder = running_run!(ctx, lead)

      other_draft = running_run!(ctx, lead)
      other_draft_a = genuine_draft!(ctx, other_draft, lead, "other-draft-a")
      other_draft_b = genuine_draft!(ctx, other_draft, lead, "other-draft-b")

      mixed = running_run!(ctx, lead)
      mixed_a = genuine_draft!(ctx, mixed, lead, "mixed-a")
      mixed_b = genuine_draft!(ctx, mixed, lead, "mixed-b")

      # Kind stage: a passed draft_shape_validation Decision must be
      # recordable through the domain API before the guard can be exercised.
      shapes = [
        matching: {matching, matching_a, shape_on!(ctx, matching, lead, matching_a, "matching")},
        other_run:
          {other_run, other_run_a, shape_on!(ctx, holder, lead, other_run_a, "other-run")},
        other_draft:
          {other_draft, other_draft_a,
           shape_on!(ctx, other_draft, lead, other_draft_b, "other-draft")},
        mixed_refs:
          {mixed, mixed_a,
           shape_on!(ctx, mixed, lead, %{mixed_a | invocation: mixed_b.invocation}, "mixed")}
      ]

      # Guard stage, matching provenance first: it passes the shape guard and
      # reaches the enrollment gate, which refuses this unqualified lead.
      [{:matching, {run, draft, shape}} | refused] = shapes

      result =
        observe(fn ->
          HandOffProposal.perform(
            gate_params(ctx, run, lead, draft, shape, :matching),
            context(ctx, run, :matching)
          )
        end)

      assert match?({:ok, %{phase: :stop}}, result),
             "B1-05: a matching passed shape check did not reach the enrollment gate: " <>
               short(result)

      assert run!(ctx, run).status == :running

      assert Enum.any?(decisions!(ctx, run), &(&1.kind == :enrollment)),
             "B1-05: a matching passed shape check did not reach the enrollment gate"

      for {label, {run, draft, shape}} <- refused do
        result =
          observe(fn ->
            HandOffProposal.perform(
              gate_params(ctx, run, lead, draft, shape, label),
              context(ctx, run, label)
            )
          end)

        assert result == {:error, {:halt, :invalid_model_output}},
               "B1-05 guard stage: a passed shape check with #{label} provenance was accepted: " <>
                 short(result)

        failed = run!(ctx, run)
        assert {failed.status, failed.status_reason} == {:failed, :invalid_model_output}

        refute Enum.any?(decisions!(ctx, run), &(&1.kind == :enrollment)),
               "B1-05: a #{label} shape check reached the enrollment gate"

        refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
        assert lead_status!(ctx, lead) == status, "B1-05: a #{label} shape check moved the lead"
      end

      {:ok, enrollments} =
        Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

      assert enrollments == []

      {:ok, drafts} =
        Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

      assert drafts == []
    end
  end

  describe "the shape check's authority (Codex B1-R1)" do
    @describetag :b1_r1

    test "a stored subject with a line break is rejected although the caller's map is single-line",
         ctx do
      lead = qualified_lead!(ctx)
      driven = drive!(ctx, lead, MultilineSubject, &%{&1 | subject: @single_line_subject})

      assert driven.stored.subject == @multiline_subject,
             "B1-R1 fixture stage: the stored subject is not the multi-line one"

      refute link?(driven.stored.body)
      refute control?(driven.supplied.subject)

      assert match?({:ok, %{passed: false}}, driven.shape),
             "B1-R1: the stored draft's subject holds a line break, but the shape check " <>
               "measured the caller's single-line map: #{short(driven.shape)}; the hand-off " <>
               "then returned #{short(driven.handoff)} and handed off " <>
               inspect(handed_off(ctx, lead))

      assert_stored_rejected!(ctx, driven, lead, "subject_not_single_line")
    end

    test "a stored link in the body is rejected although the caller's map has none", ctx do
      lead = qualified_lead!(ctx)

      driven =
        drive!(
          ctx,
          lead,
          InventedLink,
          &%{&1 | body: String.replace(&1.body, @invented_link, "")}
        )

      assert String.ends_with?(driven.stored.body, @invented_link),
             "B1-R1 fixture stage: the stored body does not end with the invented link"

      refute control?(driven.stored.subject)
      refute link?(driven.supplied.body)

      assert match?({:ok, %{passed: false}}, driven.shape),
             "B1-R1: the stored draft's body holds a link, but the shape check measured " <>
               "the caller's link-free map: #{short(driven.shape)}; the hand-off then " <>
               "returned #{short(driven.handoff)} and handed off " <>
               inspect(handed_off(ctx, lead))

      assert_stored_rejected!(ctx, driven, lead, "body_contains_url")
    end

    test "a well-shaped stored draft is handed off as stored although the caller's map is malformed",
         ctx do
      lead = qualified_lead!(ctx)

      driven =
        drive!(
          ctx,
          lead,
          FakeBrain,
          &%{&1 | subject: @multiline_subject, body: &1.body <> @invented_link}
        )

      refute control?(driven.stored.subject),
             "B1-R1 fixture stage: the stored subject is malformed"

      refute link?(driven.stored.body), "B1-R1 fixture stage: the stored body has a link"
      assert control?(driven.supplied.subject) and link?(driven.supplied.body)

      # The outcome follows the authoritative (stored, released) content:
      # the caller's map is not what is checked or handed off.
      assert match?({:ok, %{passed: true}}, driven.shape),
             "B1-R1: the stored draft is well-shaped, but the shape check measured the " <>
               "caller's map (a line break in the subject, a link in the body): " <>
               "#{short(driven.shape)}; the hand-off then returned #{short(driven.handoff)}"

      assert_stored_handed_off!(ctx, driven, lead)
    end

    test "a caller map equal to the stored draft passes and is handed off unchanged (control)",
         ctx do
      lead = qualified_lead!(ctx)
      driven = drive!(ctx, lead, FakeBrain, &Function.identity/1)

      assert driven.supplied == driven.draft.proposal
      refute control?(driven.stored.subject)
      refute link?(driven.stored.body)

      assert match?({:ok, %{passed: true}}, driven.shape),
             "B1-R1 control: a matching well-shaped draft did not pass: #{short(driven.shape)}"

      assert_stored_handed_off!(ctx, driven, lead)
    end
  end

  describe "the shape check's draft provenance (Codex B1-R1)" do
    @describetag :b1_r1

    # Each counterexample differs from the genuine pair of its run
    # (`coherent/2`) in the one association fact it names; each runs on its
    # own run (one shape check per run). The draft maps carry the genuine,
    # well-shaped proposal, so only the association can refuse them.

    test "refuses the draft's Decision paired with another invocation of the same run", ctx do
      lead = qualified_lead!(ctx)
      drafted = drafted!(ctx, lead, RecordingBrain, "b1-r1-same-run")

      # A second genuine outreach-proposal invocation of this run, through
      # the production model path, from the draft step's exact input.
      second_ctx = %{drafted.sdr | signal_id: "sig-b1-r1-second-invocation"}

      assert {:ok, _output, second} =
               Model.call(second_ctx, :outreach_proposal, one_input!(@proposal), lead.id)

      pair = %{drafted.draft | model_invocation_id: second.id}

      assert facts!(ctx, pair) == %{coherent(drafted.run, lead) | cites_invocation: false},
             "B1-R1 fixture stage: the pair is not the draft's Decision with another " <>
               "invocation of its run"

      assert_pair_refused!(
        ctx,
        drafted,
        lead,
        "the draft's Decision with another invocation of this run",
        shape_then_hand_off(drafted, lead.id, pair)
      )
    end

    test "refuses a coherent draft Decision and invocation of another run", ctx do
      lead = qualified_lead!(ctx)
      drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-this-run")
      other = drafted!(ctx, lead, FakeBrain, "b1-r1-other-run")
      pair = other.draft

      assert facts!(ctx, pair) == %{
               coherent(drafted.run, lead)
               | decision_run: other.run.id,
                 invocation_run: other.run.id
             },
             "B1-R1 fixture stage: the pair is not another run's coherent draft"

      assert_pair_refused!(
        ctx,
        drafted,
        lead,
        "another run's draft pair",
        shape_then_hand_off(drafted, lead.id, pair)
      )
    end

    test "refuses the draft's angle Decision, citing the same invocation, as the draft", ctx do
      lead = qualified_lead!(ctx)
      drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-angle")
      angle = Enum.find(decisions!(ctx, drafted.run), &(&1.kind == :angle))
      assert angle, "B1-R1 fixture stage: the draft step recorded no angle Decision"
      pair = %{drafted.draft | decision_id: angle.id}

      assert facts!(ctx, pair) == %{coherent(drafted.run, lead) | kind: :angle},
             "B1-R1 fixture stage: the pair is not the angle Decision with the draft's invocation"

      assert_pair_refused!(
        ctx,
        drafted,
        lead,
        "the angle Decision as the draft",
        shape_then_hand_off(drafted, lead.id, pair)
      )
    end

    test "refuses a deterministic check Decision of the same run as the draft", ctx do
      lead = qualified_lead!(ctx)
      drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-check")
      pair = %{drafted.draft | decision_id: drafted.claims_check.decision_id}

      assert facts!(ctx, pair) == %{
               coherent(drafted.run, lead)
               | kind: :claims_validation,
                 mode: :deterministic,
                 cites_invocation: false
             },
             "B1-R1 fixture stage: the pair is not the claims check with the draft's invocation"

      assert_pair_refused!(
        ctx,
        drafted,
        lead,
        "the claims_validation Decision as the draft",
        shape_then_hand_off(drafted, lead.id, pair)
      )
    end

    test "refuses this run's draft pair for another lead", ctx do
      lead = qualified_lead!(ctx)
      other_lead = fixture_lead!(ctx, "02")
      other_status = lead_status!(ctx, other_lead)
      drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-lead")

      assert facts!(ctx, drafted.draft) == coherent(drafted.run, lead)
      refute other_lead.id == lead.id

      assert_pair_refused!(
        ctx,
        drafted,
        lead,
        "this run's draft pair for another lead",
        shape_then_hand_off(drafted, other_lead.id, drafted.draft)
      )

      nothing_handed_off!(ctx, drafted.run, other_lead)
      assert lead_status!(ctx, other_lead) == other_status, "B1-R1: the other lead moved"
    end

    test "refuses a missing draft Decision or invocation", ctx do
      lead = qualified_lead!(ctx)

      for {label, swap} <- [
            decision: &%{&1 | decision_id: Ecto.UUID.generate()},
            invocation: &%{&1 | model_invocation_id: Ecto.UUID.generate()}
          ] do
        drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-missing-#{label}")
        pair = swap.(drafted.draft)

        assert match?({:error, _}, Agents.get_decision(pair.decision_id, actor: ctx.agent)) or
                 match?(
                   {:error, _},
                   Agents.get_model_invocation(pair.model_invocation_id, actor: ctx.agent)
                 ),
               "B1-R1 fixture stage: the #{label} of the pair exists"

        assert_pair_refused!(
          ctx,
          drafted,
          lead,
          "a missing #{label}",
          shape_then_hand_off(drafted, lead.id, pair)
        )
      end
    end

    test "passes and hands off the genuine matching pair of this run (control)", ctx do
      lead = qualified_lead!(ctx)
      drafted = drafted!(ctx, lead, FakeBrain, "b1-r1-matching")

      assert facts!(ctx, drafted.draft) == coherent(drafted.run, lead),
             "B1-R1 fixture stage: the draft step's pair is not coherent"

      {shape, handoff} = shape_then_hand_off(drafted, lead.id, drafted.draft)

      assert match?({:ok, %{passed: true}}, shape),
             "B1-R1 control: the genuine matching pair did not pass: #{short(shape)}"

      assert_stored_handed_off!(
        ctx,
        %{
          run: drafted.run,
          draft: drafted.draft,
          stored: drafted.stored,
          supplied: drafted.draft.proposal,
          shape: shape,
          handoff: handoff
        },
        lead
      )
    end
  end

  describe "the citation checks' authority (Codex B1-R1, neighbor N1-N5)" do
    @describetag :b1_r1

    test "a stored claim citing evidence not accepted for the lead is rejected although the " <>
           "caller's claim cites accepted evidence",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, UnsupportedClaim, "b1-r1-n1-unsupported")
      [stored_claim] = d.stored.claims
      accepted = accepted_ids!(ctx, lead)

      refute stored_claim.evidence_id in accepted,
             "B1-R1 fixture stage: the stored claim is supported"

      [detail] = d.draft.proposal.personalization
      supplied = %{d.draft.proposal | claims: [%{stored_claim | evidence_id: detail.evidence_id}]}
      assert detail.evidence_id in accepted

      checks = check_then_hand_off(d, lead.id, %{d.draft | proposal: supplied}, d.bundle.claims)

      assert match?({:ok, %{passed: false}}, checks.claims),
             "B1-R1: the stored claim cites evidence not accepted for the lead, but the claims " <>
               "check measured the caller's supported claim: #{short(checks.claims)}; the " <>
               "hand-off then returned #{short(checks.handoff)}"

      assert_stored_citations_rejected!(
        ctx,
        d,
        lead,
        supplied,
        checks,
        :claims_validation,
        "evidence_not_accepted_for_lead"
      )
    end

    test "a stored claim absent from the stored body is rejected although the caller's claim " <>
           "is in its body",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, ClaimNotInBody, "b1-r1-n1-not-in-body")
      [stored_claim] = d.stored.claims
      refute String.contains?(d.stored.body, stored_claim.claim)
      [detail] = d.draft.proposal.personalization
      supplied = %{d.draft.proposal | claims: [%{stored_claim | claim: detail.text}]}
      assert String.contains?(supplied.body, detail.text)

      checks = check_then_hand_off(d, lead.id, %{d.draft | proposal: supplied}, d.bundle.claims)

      assert match?({:ok, %{passed: false}}, checks.claims),
             "B1-R1: the stored claim is not in the stored body, but the claims check measured " <>
               "the caller's claim: #{short(checks.claims)}; the hand-off then returned " <>
               short(checks.handoff)

      assert_stored_citations_rejected!(
        ctx,
        d,
        lead,
        supplied,
        checks,
        :claims_validation,
        "text_not_in_body"
      )
    end

    test "a stored draft without personalization is rejected (too few) although the caller's " <>
           "map has one",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, NoPersonalization, "b1-r1-n3-none")
      assert d.stored.personalization == [], "B1-R1 fixture stage: the stored draft personalizes"
      [claim] = d.draft.proposal.claims

      supplied = %{
        d.draft.proposal
        | personalization: [%{text: claim.claim, evidence_id: claim.evidence_id}]
      }

      checks = check_then_hand_off(d, lead.id, %{d.draft | proposal: supplied}, d.bundle.claims)

      assert match?({:ok, %{passed: false}}, checks.personalization),
             "B1-R1: the stored draft has no personalization, but the personalization check " <>
               "measured the caller's item: #{short(checks.personalization)}; the hand-off " <>
               "then returned #{short(checks.handoff)}"

      assert_stored_citations_rejected!(
        ctx,
        d,
        lead,
        supplied,
        checks,
        :personalization_validation,
        :too_few
      )
    end

    test "a stored personalization item absent from the stored body is rejected although the " <>
           "caller's item is in its body",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, PersonalizationNotInBody, "b1-r1-n3-not-in-body")
      [stored_item] = d.stored.personalization
      refute String.contains?(d.stored.body, stored_item.text)
      [claim] = d.draft.proposal.claims
      supplied = %{d.draft.proposal | personalization: [%{stored_item | text: claim.claim}]}

      checks = check_then_hand_off(d, lead.id, %{d.draft | proposal: supplied}, d.bundle.claims)

      assert match?({:ok, %{passed: false}}, checks.personalization),
             "B1-R1: the stored personalization item is not in the stored body, but the " <>
               "personalization check measured the caller's item: " <>
               "#{short(checks.personalization)}; the hand-off then returned " <>
               short(checks.handoff)

      assert_stored_citations_rejected!(
        ctx,
        d,
        lead,
        supplied,
        checks,
        :personalization_validation,
        "text_not_in_body"
      )
    end

    test "a well-cited stored draft passes both checks and is handed off as stored although " <>
           "the caller's map breaks both",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n2-inverse")
      [claim] = d.draft.proposal.claims

      supplied = %{
        d.draft.proposal
        | claims: [
            %{
              claim
              | evidence_id: Ecto.UUID.generate(),
                claim: "A synthetic claim the body never states."
            }
          ],
          personalization: []
      }

      checks = check_then_hand_off(d, lead.id, %{d.draft | proposal: supplied}, d.bundle.claims)

      # The outcome follows the stored, released draft; the caller's map is
      # neither measured nor handed off.
      assert match?({{:ok, %{passed: true}}, {:ok, %{passed: true}}}, {
               checks.claims,
               checks.personalization
             }),
             "B1-R1: the stored draft is well cited, but the citation checks measured the " <>
               "caller's map: #{short({checks.claims, checks.personalization})}; the hand-off " <>
               "then returned #{short(checks.handoff)}"

      assert_stored_citations_handed_off!(ctx, d, lead, supplied, checks)
    end

    test "a matching draft passes both checks, bound to its draft and invocation, and is " <>
           "handed off (control)",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n2-matching")
      checks = check_then_hand_off(d, lead.id, d.draft, d.bundle.claims)

      assert match?({{:ok, %{passed: true}}, {:ok, %{passed: true}}}, {
               checks.claims,
               checks.personalization
             }),
             "B1-R1 control: a matching draft's citation checks did not pass"

      assert_stored_citations_handed_off!(ctx, d, lead, d.draft.proposal, checks)
    end

    # N5, one test per (listed claim, validator), each on a fresh running run
    # (Codex R2): the caller lists the claim the stored draft cites as
    # accepted; the check takes membership from the lead's accepted
    # evidence and rejects it.
    for label <- [:non_accepted, :other_lead, :missing],
        kind <- [:claims_validation, :personalization_validation] do
      @tag n5: {label, kind}
      test "N5: the #{kind} check does not accept the #{label} claim the caller lists", ctx do
        {label, kind} = ctx.n5
        lead = qualified_lead!(ctx)
        id = n5_evidence!(ctx, lead, label)
        put_env!(CitesEvidence, id)
        d = draft_only!(ctx, lead, CitesEvidence, "b1-r1-n5-#{label}-#{kind}")

        assert Enum.all?(d.stored.claims ++ d.stored.personalization, &(&1.evidence_id == id)),
               "B1-R1 fixture stage: the stored draft does not cite the #{label} claim"

        refute id in accepted_ids!(ctx, lead),
               "B1-R1 fixture stage: the #{label} claim is accepted"

        assert run!(ctx, d.run).status == :running, "B1-R1 fixture stage: the run is not running"
        evidence = d.bundle.claims ++ [%{id: id, claim: "Listed as accepted by the caller."}]
        checked = %{lead_id: lead.id, draft: d.draft, claims: evidence}
        result = observe(fn -> validator(kind).perform(checked, d.sdr) end)

        assert match?({:ok, %{passed: false}}, result),
               "B1-R1: the caller's evidence list made the #{label} claim accepted for the " <>
                 "#{kind} check: #{short(result)}"

        decision = citation_decision!(ctx, d.run, kind)
        assert {decision.mode, decision.outcome} == {:deterministic, "rejected"}
        assert [%{"index" => 0, "reasons" => reasons} | _] = decision.outcome_detail["rejected"]
        assert "evidence_not_accepted_for_lead" in reasons
        assert_citation_bound!(ctx, decision, d, lead, texts(d.stored))
        nothing_handed_off!(ctx, d.run, lead)
        assert lead_status!(ctx, lead) == :qualified
      end
    end
  end

  describe "the citation checks' draft provenance and the hand-off binding (Codex B1-R1, N6-N7)" do
    @describetag :b1_r1

    # N6, one test per (counterexample, validator), each on its own fresh
    # running run (Codex R2): the fixed fail-closed stop, no Decision of the
    # validator's kind, no hand-off, no draft text in the result or the run's
    # failure reason.
    for label <- [
          :other_invocation,
          :other_run,
          :angle,
          :deterministic,
          :other_lead,
          :missing_decision,
          :missing_invocation
        ],
        kind <- [:claims_validation, :personalization_validation] do
      @tag n6: {label, kind}
      test "N6: the #{kind} check refuses #{label} as this run's draft of this lead", ctx do
        {label, kind} = ctx.n6
        lead = qualified_lead!(ctx)
        {d, lead_id, pair} = n6_case!(ctx, lead, label)
        assert run!(ctx, d.run).status == :running, "B1-R1 fixture stage: the run is not running"
        checked = %{lead_id: lead_id, draft: pair, claims: d.bundle.claims}
        result = observe(fn -> validator(kind).perform(checked, d.sdr) end)

        assert match?({:error, {:halt, _}}, result),
               "B1-R1: the #{kind} check did not stop on #{label}: #{short(result)}"

        {:error, {:halt, reason}} = result
        stopped = run!(ctx, d.run)
        assert {stopped.status, stopped.status_reason} == {:failed, reason}

        refute Enum.any?(decisions!(ctx, d.run), &(&1.kind == kind)),
               "B1-R1: a #{kind} Decision was recorded for #{label}"

        nothing_handed_off!(ctx, d.run, lead)
        assert lead_status!(ctx, lead) == :qualified
        refute_echo!(texts(d.stored), [render(result), stopped.failure_reason || ""], label)
      end
    end

    # N7, one test per (counterexample, target check), each on its own fresh
    # running run (Codex R1): only the target citation check is wrong; its
    # companion and the shape check are passed and bound to the draft. The
    # hand-off refuses before its Lead lock (Codex R3), with no draft text
    # in the result or the run's failure reason.
    for label <- [:other_run, :other_invocation, :wrong_kind, :unbound],
        target <- [:claims_validation, :personalization_validation] do
      @tag n7: {label, target}
      test "N7: HandOffProposal refuses a #{label} #{target} check beside bound checks, " <>
             "before its lead lock",
           ctx do
        {label, target} = ctx.n7
        lead = qualified_lead!(ctx)
        responder = if label == :other_invocation, do: RecordingBrain, else: FakeBrain
        d = draft_only!(ctx, lead, responder, "b1-r1-n7-#{label}-#{target}")
        companion = companion(target)

        checks = %{
          target => n7_check!(ctx, lead, d, label, target),
          companion => passed_check!(d, lead, companion, d.draft, bound_refs!(ctx, d), "bound")
        }

        params = n7_params(d, lead, checks)
        assert run!(ctx, d.run).status == :running, "B1-R1 fixture stage: the run is not running"
        {result, queries} = with_queries(fn -> HandOffProposal.perform(params, d.sdr) end)

        assert result == {:error, {:halt, :invalid_model_output}},
               "B1-R1: HandOffProposal did not refuse the #{label} #{target} check before any " <>
                 "write: #{short(result)}"

        refute lead_locked?(queries),
               "B1-R1: the hand-off took its Lead lock for the #{label} #{target} check"

        stopped = run!(ctx, d.run)
        assert {stopped.status, stopped.status_reason} == {:failed, :invalid_model_output}

        refute Enum.any?(decisions!(ctx, d.run), &(&1.kind == :enrollment)),
               "B1-R1: the #{label} #{target} check reached the enrollment gate"

        nothing_handed_off!(ctx, d.run, lead)
        assert lead_status!(ctx, lead) == :qualified
        refute_echo!(texts(d.stored), [render(result), stopped.failure_reason || ""], label)
      end
    end

    test "N7 control: passed checks bound to the draft reach the lead lock and are handed off",
         ctx do
      lead = qualified_lead!(ctx)
      d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n7-bound")
      bound = bound_refs!(ctx, d)

      checks = %{
        claims_validation: passed_check!(d, lead, :claims_validation, d.draft, bound, "bound"),
        personalization_validation:
          passed_check!(d, lead, :personalization_validation, d.draft, bound, "bound")
      }

      {result, queries} =
        with_queries(fn -> HandOffProposal.perform(n7_params(d, lead, checks), d.sdr) end)

      assert match?({:ok, %{phase: :review}}, result),
             "B1-R1 control: bound passed checks were not handed off: #{short(result)}"

      assert lead_locked?(queries), "B1-R1 control: the probe saw no Lead lock in a hand-off"
      assert "sdr.draft.completed" in signal_types(ctx.tenant, d.run)
      assert lead_status!(ctx, lead) == :in_outreach
    end
  end

  ## B1-R1 neighbor helpers for the independent N5-N7 cases (Codex R1-R3).

  defp validator(:claims_validation), do: ValidateClaims
  defp validator(:personalization_validation), do: ValidatePersonalization

  defp companion(:claims_validation), do: :personalization_validation
  defp companion(:personalization_validation), do: :claims_validation

  # The draft's own Decision and invocation, as input refs.
  defp bound_refs!(ctx, d) do
    {:ok, decision} = Agents.get_decision(d.draft.decision_id, actor: ctx.agent)
    {:ok, invocation} = Agents.get_model_invocation(d.draft.model_invocation_id, actor: ctx.agent)
    [decision, invocation]
  end

  # The claim id the caller lists for N5: this lead's non-accepted claim,
  # another lead's accepted claim (after its own genuine research), or none.
  defp n5_evidence!(ctx, lead, :non_accepted) do
    {:ok, rejected} =
      Research.list_records(Research.EvidenceClaim,
        filter: [lead_id: lead.id, quality: :rejected],
        actor: ctx.admin
      )

    assert rejected != [], "B1-R1 fixture stage: the lead has no non-accepted evidence claim"
    hd(rejected).id
  end

  defp n5_evidence!(ctx, _lead, :other_lead) do
    %{lead: other_lead} = assign_with!(ctx, "02", MultilineSubject)
    drain!()
    accepted = accepted_ids!(ctx, other_lead)
    assert accepted != [], "B1-R1 fixture stage: the other lead has no accepted evidence"
    hd(accepted)
  end

  defp n5_evidence!(_ctx, _lead, :missing), do: Ecto.UUID.generate()

  # One N6 counterexample on a fresh run `d`: `{d, lead_id, pair}`, its
  # fixture fact asserted (it differs from `coherent/2` in the named fact).
  defp n6_case!(ctx, lead, :other_invocation) do
    d = draft_only!(ctx, lead, RecordingBrain, "b1-r1-n6-other-invocation")
    second = second_invocation!(d, lead, "sig-b1-r1-n6-second-invocation")
    pair = %{d.draft | model_invocation_id: second.id}
    assert facts!(ctx, pair) == %{coherent(d.run, lead) | cites_invocation: false}
    {d, lead.id, pair}
  end

  defp n6_case!(ctx, lead, :other_run) do
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-this-run")
    other = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-other-run")

    assert facts!(ctx, other.draft) == %{
             coherent(d.run, lead)
             | decision_run: other.run.id,
               invocation_run: other.run.id
           }

    {d, lead.id, other.draft}
  end

  defp n6_case!(ctx, lead, :angle) do
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-angle")
    angle = Enum.find(decisions!(ctx, d.run), &(&1.kind == :angle))
    assert angle, "B1-R1 fixture stage: the draft step recorded no angle Decision"
    pair = %{d.draft | decision_id: angle.id}
    assert facts!(ctx, pair) == %{coherent(d.run, lead) | kind: :angle}
    {d, lead.id, pair}
  end

  defp n6_case!(ctx, lead, :deterministic) do
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-deterministic")
    budget = Enum.find(decisions!(ctx, d.run), &(&1.kind == :budget_reservation))
    assert budget, "B1-R1 fixture stage: the draft call recorded no budget_reservation Decision"
    pair = %{d.draft | decision_id: budget.id}

    assert facts!(ctx, pair) == %{
             coherent(d.run, lead)
             | kind: :budget_reservation,
               mode: :deterministic,
               cites_invocation: false
           }

    {d, lead.id, pair}
  end

  defp n6_case!(ctx, lead, :other_lead) do
    other_lead = fixture_lead!(ctx, "02")
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-other-lead")
    assert facts!(ctx, d.draft) == coherent(d.run, lead)
    refute other_lead.id == lead.id
    {d, other_lead.id, d.draft}
  end

  defp n6_case!(ctx, lead, :missing_decision) do
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-missing-decision")
    pair = %{d.draft | decision_id: Ecto.UUID.generate()}
    assert match?({:error, _}, Agents.get_decision(pair.decision_id, actor: ctx.agent))
    {d, lead.id, pair}
  end

  defp n6_case!(ctx, lead, :missing_invocation) do
    d = draft_only!(ctx, lead, FakeBrain, "b1-r1-n6-missing-invocation")
    pair = %{d.draft | model_invocation_id: Ecto.UUID.generate()}

    assert match?(
             {:error, _},
             Agents.get_model_invocation(pair.model_invocation_id, actor: ctx.agent)
           )

    {d, lead.id, pair}
  end

  # A second genuine outreach-proposal invocation of `d`'s run, through the
  # production model path, from the draft step's recorded input (`d` must
  # have drafted with `RecordingBrain`).
  defp second_invocation!(d, lead, signal_id) do
    assert {:ok, _output, second} =
             Model.call(
               %{d.sdr | signal_id: signal_id},
               :outreach_proposal,
               one_input!(@proposal),
               lead.id
             )

    second
  end

  # The wrong `target` check of one N7 case, recorded through the domain API
  # (kind stage asserted by `passed_check!/6`).
  defp n7_check!(ctx, lead, _d, :other_run, target) do
    other = draft_only!(ctx, lead, FakeBrain, "b1-r1-n7-other-run-#{target}")
    passed_check!(other, lead, target, other.draft, bound_refs!(ctx, other), "bound")
  end

  defp n7_check!(ctx, lead, d, :other_invocation, target) do
    second = second_invocation!(d, lead, "sig-b1-r1-n7-second-invocation")
    [decision, _invocation] = bound_refs!(ctx, d)
    mixed = %{d.draft | model_invocation_id: second.id}
    passed_check!(d, lead, target, mixed, [decision, second], "other-pair")
  end

  defp n7_check!(ctx, lead, d, :wrong_kind, target),
    do: passed_check!(d, lead, companion(target), d.draft, bound_refs!(ctx, d), "wrong-kind")

  defp n7_check!(_ctx, lead, d, :unbound, target),
    do: passed_check!(d, lead, target, d.draft, [], "unbound")

  defp n7_params(d, lead, checks),
    do: %{
      lead_id: lead.id,
      draft: d.draft,
      claims_check: Map.fetch!(checks, :claims_validation),
      personalization_check: Map.fetch!(checks, :personalization_validation),
      shape_check: genuine_shape!(d, lead),
      plan: d.plan
    }

  # `fun`'s result (observed) and every query this process ran meanwhile
  # (the `run_recovery_test.exs` telemetry style).
  defp with_queries(fun) do
    parent = self()
    handler = "b1-r1-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:b1_r1_query, IO.iodata_to_binary(metadata.query)})
      end,
      nil
    )

    result =
      try do
        observe(fun)
      after
        :telemetry.detach(handler)
      end

    {result, collect_b1_r1_queries([])}
  end

  defp collect_b1_r1_queries(acc) do
    receive do
      {:b1_r1_query, query} -> collect_b1_r1_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The hand-off's first lock: the Lead row `FOR UPDATE`.
  defp lead_locked?(queries),
    do:
      Enum.any?(
        queries,
        &(String.starts_with?(&1, "SELECT") and String.contains?(&1, ~s(FROM "leads")) and
            String.contains?(&1, "FOR UPDATE"))
      )

  # No line of `texts` in any of `fields` (refusal results, failure reasons).
  defp refute_echo!(texts, fields, label) do
    for text <- texts,
        line <- String.split(text, ~r/\p{Cc}+/u, trim: true),
        String.length(line) >= 12,
        field <- fields do
      refute String.contains?(field, line),
             "B1-R1: the refusal of #{label} echoes draft text: #{short(line)}"
    end
  end
end

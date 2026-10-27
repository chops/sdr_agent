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

  defp gate_params(ctx, lead, draft, shape),
    do: %{
      lead_id: lead.id,
      draft: %{
        decision_id: draft.decision.id,
        model_invocation_id: draft.invocation.id,
        proposal: %{}
      },
      claims_check: %{passed: true, decision_id: Ecto.UUID.generate()},
      personalization_check: %{passed: true, decision_id: Ecto.UUID.generate()},
      shape_check: %{passed: true, decision_id: shape.id},
      plan: %{campaign_id: ctx.campaign_id, step: %{id: Ecto.UUID.generate()}}
    }

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
            gate_params(ctx, lead, draft, shape),
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
              gate_params(ctx, lead, draft, shape),
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
end

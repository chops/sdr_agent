defmodule SdrAgent.SDR.FirstTouchDraftTest do
  @moduledoc """
  B1-05 (map row N4; `docs/product/c4/readiness.md` C4-R5, C4-R9, C4-R13,
  test 21a): the first-touch draft is built from the run's settings
  snapshot and passes a deterministic shape rule before hand-off.

    * The outreach-proposal model input carries the snapshot's offering
      profile, writing guide and research brief (from which the model
      derives the angle): the bound revisions, never ones saved after the
      run was created, or the built-in defaults by version for the guide and
      brief when none is saved. A withheld booking link never reaches it.
    * `ValidateDraftShape` records a deterministic `draft_shape_validation`
      Decision (rule `sdr.draft_shape`): the subject is one line, and the
      body carries no URL, since this slice supplies no usable booking link
      (C4-R9: no step invents a link). A rejected shape fails the run as
      invalid model output and nothing is handed to review, as for
      `ValidateClaims`.

  Hermetic: Fake model provider; the recording responder
  (`SdrAgent.SettingsFixtures.RecordingBrain`) and test responders built on
  `SdrAgent.SDR.FakeBrain`; synthetic content only.

  RED: `DraftEmail` sends no offering, guide or brief; there is no shape
  rule, so a multi-line subject or an invented link is handed to review.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]
  import SdrAgent.SettingsFixtures, only: [content: 2, save!: 3]

  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SettingsFixtures.RecordingBrain

  @moduletag :b1_05

  @proposal "sdr.outreach_proposal"

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

  setup ctx do
    save!(:offering_profile, Fixtures.offering_profile(), ctx.admin)
    put_env!(RecordingBrain, self())
    :ok
  end

  defp assign_with!(ctx, responder),
    do: assign!(ctx, "01", model: [provider_options: [responder: responder]])

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

  defp assert_rejected!(ctx, run, reason) do
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

    refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
    assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)
  end

  describe "the draft input" do
    test "carries the snapshot's offering, guide and brief, and no withheld booking link",
         ctx do
      guide = "Write two short paragraphs and ask one question (guide revision one)."
      brief = "Look for synthetic dock scheduling needs (brief revision one)."
      save!(:writing_guide, %{text: guide}, ctx.admin)
      save!(:research_brief, content(:research_brief, %{guidance: brief}), ctx.admin)
      save!(:booking_link, %{url: "https://book.example.test/demo/intro"}, ctx.admin)
      put_env!(:booking_link_guard, {SdrAgent.SettingsFixtures, :deny_every_host})

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

      refute rendered =~ "book.example.test", "B1-05: a withheld booking link reached the draft"
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

  describe "the shape rule" do
    test "a well-shaped draft records a passed draft_shape_validation before hand-off", ctx do
      %{run: run} = assign!(ctx, "01")
      drain!()

      run = run!(ctx, run)
      assert run.status == :succeeded

      shape = shape_decision(ctx, run)
      assert shape.mode == :deterministic
      assert shape.rule_id == "sdr.draft_shape"
      assert shape.outcome == "passed"

      {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)
      refute proposal.output.subject =~ ~r/[\r\n]/
      refute proposal.output.body =~ ~r/https?:\/\//i
    end

    test "a multi-line subject is rejected deterministically and not handed to review", ctx do
      %{run: run} = assign_with!(ctx, MultilineSubject)
      drain!()
      assert_rejected!(ctx, run, "subject_not_single_line")
    end

    test "a body with a link the run did not supply is rejected and not handed to review",
         ctx do
      %{run: run} = assign_with!(ctx, InventedLink)
      drain!()
      assert_rejected!(ctx, run, "body_contains_url")
    end
  end
end

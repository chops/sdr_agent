defmodule SdrAgent.SDR.ResearchBriefTest do
  @moduledoc """
  B1-04 (map row N3; `docs/product/c4/readiness.md` sections 3.3 and 6,
  C4-R5, C4-R10, C4-R11): ResearchLeadFlow is driven by the run's settings
  snapshot.

    * The evidence-extraction model input carries the snapshot's research
      brief (`guidance` and its one depth, D-052): the bound revision, never
      a revision saved after the run was created, or the built-in default by
      version when none is saved.
    * The snapshot's research caps (`research_max_sources`,
      `research_max_source_chars`, `research_max_total_source_chars`) bound
      the sources sent to the model; higher-trust sources are sent first and
      a cut source keeps a prefix of its stored content, so every claim is
      still grounded in a source that was sent.
    * A deterministic `research_caps` Decision (rule `sdr.research_caps`)
      records the caps applied, against the run's snapshot, so the run page
      can show them; the registry labels these three caps checked at use
      and still claims nothing for C5's search and fetch caps.

  Hermetic: Fake model provider with the recording responder
  (`SdrAgent.SettingsFixtures.RecordingBrain`); synthetic content only.

  RED: the research flow reads no settings. The extraction input has no
  `research_brief`, every source is sent whole, no `research_caps` Decision
  is recorded, and the registry labels every research cap not yet enforced.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]
  import SdrAgent.SettingsFixtures, only: [content: 2, limit_defaults: 0, save!: 3]

  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Audit
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Research
  alias SdrAgent.SettingsFixtures.RecordingBrain

  @moduletag :b1_04

  @extraction "sdr.evidence_extraction"
  @enforced [:research_max_sources, :research_max_source_chars, :research_max_total_source_chars]
  @trust_rank %{high: 0, medium: 1, low: 2}

  setup ctx do
    save!(:offering_profile, Fixtures.offering_profile(), ctx.admin)
    put_env!(RecordingBrain, self())
    :ok
  end

  defp assign_recorded!(ctx),
    do: assign!(ctx, "01", model: [provider_options: [responder: RecordingBrain]])

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

  defp codepoints(text), do: text |> String.codepoints() |> length()

  defp artifacts!(ctx, run) do
    {:ok, artifacts} =
      Research.list_records(Research.ResearchArtifact,
        filter: [agent_run_id: run.id],
        actor: ctx.admin
      )

    artifacts
  end

  defp content!(ctx, artifact) do
    {:ok, content} = Audit.read_content(artifact.content_sha256, actor: ctx.admin)
    content
  end

  defp caps_decision!(ctx, run) do
    caps = ctx |> decisions!(run) |> Enum.filter(&(&1.kind == :research_caps))

    assert length(caps) == 1,
           "B1-04: the run recorded #{length(caps)} research_caps Decisions, expected one"

    hd(caps)
  end

  defp snapshot_ref?(decision, run) do
    Enum.any?(
      decision.input_refs,
      &(&1.resource == "SdrAgent.Agents.RunSettingsSnapshot" and &1.id == run.settings_snapshot_id)
    )
  end

  defp limits_detail(limits),
    do: Map.new(@enforced, &{Atom.to_string(&1), Map.fetch!(limits, &1)})

  describe "the research brief" do
    test "the extraction input carries the snapshot's brief and depth, not a later save", ctx do
      bound = "Look for synthetic dock scheduling needs (brief revision one)."
      later = "Look for synthetic yard congestion (brief revision two)."
      save!(:research_brief, content(:research_brief, %{guidance: bound}), ctx.admin)

      %{run: run} = assign_recorded!(ctx)
      save!(:research_brief, content(:research_brief, %{guidance: later}), ctx.admin)
      drain!()

      input = one_input!(@extraction)
      brief = Map.get(input, :research_brief)
      assert brief, "B1-04: the evidence-extraction input carries no research_brief"
      assert Map.get(brief, :guidance) == bound, "B1-04: the brief is not the bound revision"
      assert to_string(Map.get(brief, :depth)) == "standard"

      refute render(input) =~ "brief revision two",
             "B1-04: a brief saved after the run was created reached its research"

      assert "sdr.research.completed" in signal_types(ctx.tenant, run)
    end

    test "without a saved brief the extraction input carries the built-in default", ctx do
      assign_recorded!(ctx)
      drain!()

      default = CodeDefaults.current(:research_brief)
      brief = Map.get(one_input!(@extraction), :research_brief)
      assert brief, "B1-04: the evidence-extraction input carries no research_brief"

      assert Map.get(brief, :guidance) == default.content.guidance,
             "B1-04: the built-in default brief version #{default.version} was not used"

      assert to_string(Map.get(brief, :depth)) == to_string(default.content.depth)
    end
  end

  describe "research caps" do
    test "default caps send every source whole and record within_caps against the snapshot",
         ctx do
      %{run: run} = assign_recorded!(ctx)
      drain!()

      sources = one_input!(@extraction).sources
      artifacts = artifacts!(ctx, run)

      caps = caps_decision!(ctx, run)
      assert caps.mode == :deterministic
      assert caps.rule_id == "sdr.research_caps"
      assert caps.outcome == "within_caps"
      assert snapshot_ref?(caps, run), "B1-04: the caps Decision does not cite the run's snapshot"

      assert caps.outcome_detail["limits"] == limits_detail(limit_defaults())
      assert caps.outcome_detail["sources_available"] == length(artifacts)
      assert caps.outcome_detail["sources_sent"] == length(sources)
      assert caps.outcome_detail["sources_dropped"] == 0
      assert caps.outcome_detail["sources_truncated"] == 0

      assert caps.outcome_detail["source_chars_sent"] ==
               sources |> Enum.map(&codepoints(&1.content)) |> Enum.sum()

      assert length(sources) == length(artifacts)
    end

    test "lowered caps bound the sources sent, higher trust first, and record capped", ctx do
      limits =
        content(:operational_limits, %{
          research_max_sources: 2,
          research_max_source_chars: 500,
          research_max_total_source_chars: 600
        })

      save!(:operational_limits, limits, ctx.admin)
      %{run: run, lead: lead} = assign_recorded!(ctx)
      drain!()

      sources = one_input!(@extraction).sources
      artifacts = artifacts!(ctx, run)
      assert length(artifacts) > 2, "setup: fixture lead 01 has #{length(artifacts)} sources"

      assert length(sources) in 1..2,
             "B1-04: #{length(sources)} sources sent under research_max_sources 2"

      for source <- sources do
        assert codepoints(source.content) <= 500,
               "B1-04: a #{source.source_type} source of #{codepoints(source.content)} " <>
                 "characters was sent under research_max_source_chars 500"
      end

      chars = sources |> Enum.map(&codepoints(&1.content)) |> Enum.sum()

      assert chars <= 600,
             "B1-04: #{chars} source characters sent under research_max_total_source_chars 600"

      # Higher-trust sources are sent before lower-trust ones.
      rank = &Map.fetch!(@trust_rank, &1)

      expected =
        artifacts
        |> Enum.map(& &1.trust_level)
        |> Enum.sort_by(rank)
        |> Enum.take(length(sources))

      assert sources |> Enum.map(& &1.trust_level) |> Enum.sort_by(rank) == expected,
             "B1-04: a lower-trust source was sent while a higher-trust one was dropped"

      # Each sent source is a recorded artifact; a cut one keeps a prefix.
      by_key = Map.new(artifacts, &{{&1.source_type, &1.source_url}, &1})

      sent =
        for source <- sources do
          artifact = Map.get(by_key, {source.source_type, source.url})
          assert artifact, "B1-04: a sent source is not one of the run's artifacts"
          full = content!(ctx, artifact)
          assert String.starts_with?(full, source.content), "B1-04: a cut source is not a prefix"
          {artifact.id, source.content != full}
        end

      sent_ids = Enum.map(sent, &elem(&1, 0))

      {:ok, claims} =
        Research.list_records(Research.EvidenceClaim,
          filter: [lead_id: lead.id],
          actor: ctx.admin
        )

      assert Enum.all?(claims, &(&1.research_artifact_id in sent_ids)),
             "B1-04: a claim cites a source that was not sent to the model"

      caps = caps_decision!(ctx, run)
      assert caps.mode == :deterministic
      assert caps.outcome == "capped"
      assert snapshot_ref?(caps, run), "B1-04: the caps Decision does not cite the run's snapshot"

      detail = caps.outcome_detail
      assert detail["limits"] == limits_detail(limits)
      assert detail["sources_available"] == length(artifacts)
      assert detail["sources_sent"] == length(sources)
      assert detail["sources_sent"] + detail["sources_dropped"] == length(artifacts)
      assert detail["sources_truncated"] == Enum.count(sent, &elem(&1, 1))
      assert detail["source_chars_sent"] == chars
    end

    test "the registry labels B1-04's caps checked at use and claims nothing for C5's" do
      rules = Map.new(Safeguards.limit_rules())

      for field <- @enforced do
        assert Map.fetch!(rules, field).enforced_by,
               "B1-04: #{field} is still registered as not yet enforced"
      end

      for field <- [:research_max_search_requests, :research_max_page_fetches] do
        assert is_nil(Map.fetch!(rules, field).enforced_by),
               "B1-04: #{field} is C5's (search and fetch adapters) and must stay unclaimed"
      end
    end
  end
end

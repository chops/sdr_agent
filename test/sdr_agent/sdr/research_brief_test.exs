defmodule SdrAgent.SDR.ResearchBriefTest do
  @moduledoc """
  B1-04 (map row N3; `docs/product/c4/readiness.md` sections 3.3 and 6,
  C4-R5, C4-R10, C4-R11; plan `claude-b1-research-draft-plan-r2.md`):
  ResearchLeadFlow is driven by the run's settings snapshot.

    * The evidence-extraction model input carries the snapshot's research
      brief (`guidance` and its one depth, D-052): the bound revision, never
      a revision saved after the run was created, or the built-in default by
      version when none is saved.
    * The snapshot's three source caps (`research_max_sources`,
      `research_max_source_chars`, `research_max_total_source_chars`) are
      applied to the sources in a fixed order: trust `high`, `medium`, `low`,
      then the stable flow order (CRM, website, search results in search
      order, fetched pages in search order). At most `research_max_sources`
      are kept; each is cut to the longest prefix of whole graphemes whose
      code-point length is within both its own cap and the remaining total;
      a source with nothing left is dropped; only the sent list is
      indexed. The tests compute that expected list from the stored
      artifacts and compare it exactly (identities, order and text).
    * A quote is grounded only wholly inside the prefix that was sent: a
      quote from an unsent suffix, or from a dropped source, is ungrounded
      and never becomes an EvidenceClaim; every persisted span ends inside
      its sent prefix.
    * A deterministic `research_caps` Decision (rule `sdr.research_caps`)
      records the caps applied, against the run's snapshot; the registry
      labels these three caps checked at use and still claims nothing for
      C5's search and fetch caps.

  Hermetic: Fake model provider with the recording responder
  (`SdrAgent.SettingsFixtures.RecordingBrain`) and test responders and web
  adapters built on the fixtures; synthetic content only.

  RED: the research flow reads no settings. The extraction input has no
  `research_brief`; every source is sent whole in flow order; any quote of
  any source is grounded against its full content; no `research_caps`
  Decision is recorded; the registry labels every research cap not yet
  enforced.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]
  import SdrAgent.SettingsFixtures, only: [content: 2, limit_defaults: 0, save!: 3]

  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Audit
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Integrations.Fixtures, as: Sources
  alias SdrAgent.Integrations.FixtureWeb
  alias SdrAgent.Research
  alias SdrAgent.SettingsFixtures.RecordingBrain

  @moduletag :b1_04

  @extraction "sdr.evidence_extraction"
  @enforced [:research_max_sources, :research_max_source_chars, :research_max_total_source_chars]
  @trust_rank %{high: 0, medium: 1, low: 2}
  @lowered %{
    research_max_sources: 2,
    research_max_source_chars: 500,
    research_max_total_source_chars: 600
  }

  defmodule BoundaryWeb do
    @moduledoc false
    @behaviour SdrAgent.Integrations.WebFetch

    # 99 ASCII code points, then "é" as e + U+0301 (one grapheme, two code
    # points) straddling the 100th code point, then more text.
    @content String.duplicate("a", 99) <> "é is the boundary grapheme. Then more text."

    def content, do: @content

    @impl true
    def fetch(url) do
      with {:ok, page} <- FixtureWeb.fetch(url) do
        if page.source_type == :company_website,
          do: {:ok, %{page | content: @content}},
          else: {:ok, page}
      end
    end
  end

  defmodule UnsentQuotes do
    @moduledoc false
    alias SdrAgent.Integrations.Fixtures, as: Sources
    alias SdrAgent.SettingsFixtures.RecordingBrain

    @doc "The website's last sentence (beyond the 100 code points left for it)."
    def suffix_quote(domain),
      do: page("https://#{domain}").content |> sentences() |> List.last()

    @doc "The news page's first sentence (the news page is dropped under the caps)."
    def dropped_quote(domain),
      do: page(news_url(domain)).content |> sentences() |> hd()

    def respond("sdr.evidence_extraction" = op, %{company: %{domain: domain}} = input) do
      output = RecordingBrain.respond(op, input)
      site = Enum.find(input.sources, &(&1.source_type == :company_website))

      adversarial = [
        claim(site && site.index, suffix_quote(domain)),
        claim(2, dropped_quote(domain))
      ]

      %{output | claims: output.claims ++ adversarial}
    end

    def respond(op, input), do: RecordingBrain.respond(op, input)

    defp claim(index, quote),
      do: %{
        source: index,
        claim: quote,
        quote: quote,
        confidence: 0.9,
        quality: "accepted",
        reason: "adversarial quote outside the sent text"
      }

    defp page(url), do: Map.fetch!(Sources.pages(), Sources.normalize(url))

    defp news_url(domain),
      do: "https://news.example.test/#{domain |> String.split(".") |> hd()}/revenue-team"

    defp sentences(text), do: String.split(text, ~r/(?<=\.)\s+/, trim: true)
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

  defp claims!(ctx, lead) do
    {:ok, claims} =
      Research.list_records(Research.EvidenceClaim, filter: [lead_id: lead.id], actor: ctx.admin)

    claims
  end

  # The run's sources in the stable flow order the plan names (never the
  # order of a database read): CRM, company website, search results in the
  # fixture search order, then fetched pages in that order.
  defp flow_sources!(ctx, run) do
    artifacts = artifacts!(ctx, run)
    by_type = Enum.group_by(artifacts, & &1.source_type)
    assert [crm] = Map.get(by_type, :crm_record, [])
    assert [site] = Map.get(by_type, :company_website, [])
    account = Enum.find(Fixtures.accounts(), &(&1.website_url == site.source_url))
    assert account, "setup: no fixture account for #{site.source_url}"
    order = for result <- Sources.search_results(account.name, account.domain), do: result.url
    position = fn artifact -> Enum.find_index(order, &(&1 == artifact.source_url)) end
    searches = by_type |> Map.get(:search_result, []) |> Enum.sort_by(position)

    pages =
      artifacts
      |> Enum.reject(&(&1.source_type in [:crm_record, :company_website, :search_result]))
      |> Enum.sort_by(position)

    assert length(artifacts) == 2 + length(searches) + length(pages)

    for artifact <- [crm, site | searches] ++ pages do
      %{
        id: artifact.id,
        key: {artifact.source_type, artifact.source_url},
        trust_level: artifact.trust_level,
        full: content!(ctx, artifact)
      }
    end
  end

  # The longest prefix of whole graphemes of at most `max` code points.
  defp grapheme_prefix(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
      next = used + codepoints(grapheme)
      if next <= max, do: {:cont, {[grapheme | acc], next}}, else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # The plan's selection, computed independently: `[{source, sent_text}]`.
  defp expected_sent(flow, limits) do
    flow
    |> Enum.with_index()
    |> Enum.sort_by(fn {source, index} ->
      {Map.fetch!(@trust_rank, source.trust_level), index}
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(limits.research_max_sources)
    |> Enum.map_reduce(limits.research_max_total_source_chars, fn source, remaining ->
      text = grapheme_prefix(source.full, min(limits.research_max_source_chars, remaining))
      {{source, text}, remaining - codepoints(text)}
    end)
    |> elem(0)
    |> Enum.reject(fn {_source, text} -> text == "" end)
  end

  defp sent_view(sources),
    do: Enum.map(sources, &{{&1.source_type, &1.url}, &1.index, &1.content})

  defp expected_view(expected) do
    expected
    |> Enum.with_index()
    |> Enum.map(fn {{source, text}, index} -> {source.key, index, text} end)
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

  defp assert_caps_detail!(caps, flow, expected, limits) do
    detail = caps.outcome_detail
    assert detail["limits"] == limits_detail(limits)
    assert detail["sources_available"] == length(flow)
    assert detail["sources_sent"] == length(expected)
    assert detail["sources_dropped"] == length(flow) - length(expected)

    assert detail["sources_truncated"] ==
             Enum.count(expected, fn {source, text} -> text != source.full end)

    assert detail["source_chars_sent"] ==
             expected |> Enum.map(fn {_source, text} -> codepoints(text) end) |> Enum.sum()
  end

  defp save_lowered!(ctx),
    do: save!(:operational_limits, content(:operational_limits, @lowered), ctx.admin)

  describe "the research brief" do
    test "the extraction input carries the snapshot's brief and depth, not a later save", ctx do
      bound = "Look for synthetic dock scheduling needs (brief revision one)."
      later = "Look for synthetic yard congestion (brief revision two)."
      save!(:research_brief, content(:research_brief, %{guidance: bound}), ctx.admin)

      %{run: run} = assign_with!(ctx, RecordingBrain)
      save!(:research_brief, content(:research_brief, %{guidance: later}), ctx.admin)
      drain!()

      input = one_input!(@extraction)
      brief = Map.get(input, :research_brief)
      assert brief, "B1-04: the evidence-extraction input carries no research_brief"
      assert Map.get(brief, :guidance) == bound, "B1-04: the brief is not the bound revision"
      assert to_string(Map.get(brief, :depth)) == "standard"

      refute render(input) =~ "brief revision two",
             "B1-04: a brief saved after the run was created reached its research"

      refute Map.has_key?(input, :booking_link), "B1-04: the extraction input names a link slot"
      assert "sdr.research.completed" in signal_types(ctx.tenant, run)
    end

    test "without a saved brief the extraction input carries the built-in default", ctx do
      assign_with!(ctx, RecordingBrain)
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
    test "default caps send every source whole, trust first, and record within_caps", ctx do
      %{run: run} = assign_with!(ctx, RecordingBrain)
      drain!()

      sources = one_input!(@extraction).sources
      flow = flow_sources!(ctx, run)
      expected = expected_sent(flow, limit_defaults())

      assert sent_view(sources) == expected_view(expected),
             "B1-04: the sources sent are not every source, whole, in trust-then-flow order"

      caps = caps_decision!(ctx, run)
      assert caps.mode == :deterministic
      assert caps.rule_id == "sdr.research_caps"
      assert caps.outcome == "within_caps"
      assert snapshot_ref?(caps, run), "B1-04: the caps Decision does not cite the run's snapshot"
      assert_caps_detail!(caps, flow, expected, limit_defaults())
      assert caps.outcome_detail["sources_dropped"] == 0
      assert caps.outcome_detail["sources_truncated"] == 0
    end

    test "the snapshot's lowered caps select, cut and index exactly; a later save is ignored",
         ctx do
      save_lowered!(ctx)
      %{run: run, lead: lead} = assign_with!(ctx, RecordingBrain)

      # Saved after the run was created: the run keeps its snapshot's caps.
      save!(
        :operational_limits,
        content(:operational_limits, %{
          research_max_sources: 1,
          research_max_source_chars: 500,
          research_max_total_source_chars: 500
        }),
        ctx.admin
      )

      drain!()

      sources = one_input!(@extraction).sources
      flow = flow_sources!(ctx, run)
      expected = expected_sent(flow, @lowered)
      assert length(flow) > 2, "setup: fixture lead 01 has #{length(flow)} sources"

      assert sent_view(sources) == expected_view(expected),
             "B1-04: the sent sources differ from the snapshot caps applied in " <>
               "trust-then-flow order: #{inspect(Enum.map(sources, &{&1.source_type, &1.url}))}"

      # Fixture facts behind the exact values: the CRM record (high trust,
      # 593 code points) is cut to 500; the website wins the medium-trust
      # tie with the news page by flow order and gets the 100 left.
      assert Enum.map(expected, fn {source, _text} -> elem(source.key, 0) end) ==
               [:crm_record, :company_website]

      assert expected |> Enum.map(fn {_source, text} -> codepoints(text) end) == [500, 100]

      # Every persisted span lies inside the prefix that was sent.
      sent_length = Map.new(expected, fn {source, text} -> {source.id, codepoints(text)} end)

      for claim <- claims!(ctx, lead) do
        assert Map.has_key?(sent_length, claim.research_artifact_id),
               "B1-04: a claim cites a source that was not sent"

        assert claim.source_location.char_end <=
                 Map.fetch!(sent_length, claim.research_artifact_id),
               "B1-04: a claim's span ends beyond the prefix that was sent"
      end

      caps = caps_decision!(ctx, run)
      assert caps.mode == :deterministic
      assert caps.outcome == "capped"
      assert snapshot_ref?(caps, run), "B1-04: the caps Decision does not cite the run's snapshot"
      assert_caps_detail!(caps, flow, expected, @lowered)
    end

    test "a cut never splits a grapheme: the prefix stops before a two-code-point é", ctx do
      put_env!(:integrations, web: BoundaryWeb)
      save_lowered!(ctx)
      %{run: run} = assign_with!(ctx, RecordingBrain)
      drain!()

      sources = one_input!(@extraction).sources
      flow = flow_sources!(ctx, run)
      expected = expected_sent(flow, @lowered)
      site = Enum.find(sources, &(&1.source_type == :company_website))
      assert site, "setup: the website was not sent"

      # 100 code points remain for the website; "é" would make 101.
      assert site.content == String.duplicate("a", 99),
             "B1-04: the website was not cut to whole graphemes within its 100 code points: " <>
               inspect(String.slice(site.content, 95, 10))

      assert sent_view(sources) == expected_view(expected)
      assert_caps_detail!(caps_decision!(ctx, run), flow, expected, @lowered)
    end

    test "quotes from an unsent suffix or a dropped source are never grounded", ctx do
      save_lowered!(ctx)
      %{run: run, lead: lead} = assign_with!(ctx, UnsentQuotes)
      drain!()

      input = one_input!(@extraction)
      domain = input.company.domain
      suffix = UnsentQuotes.suffix_quote(domain)
      dropped = UnsentQuotes.dropped_quote(domain)
      quotes = Enum.map(claims!(ctx, lead), & &1.quote)

      refute suffix in quotes,
             "B1-04: a quote from the website's unsent suffix became an EvidenceClaim"

      refute dropped in quotes, "B1-04: a quote from a dropped source became an EvidenceClaim"

      site = Enum.find(input.sources, &(&1.source_type == :company_website))
      assert site, "setup: the website was not sent"
      refute String.contains?(site.content, suffix), "setup: the suffix quote was sent"
      refute Enum.any?(input.sources, &String.contains?(&1.content, dropped))

      ungrounded =
        ctx
        |> decisions!(run)
        |> Enum.filter(&(&1.kind == :evidence_quality and &1.outcome == "ungrounded"))

      assert length(ungrounded) >= 2,
             "B1-04: the two adversarial quotes were not recorded ungrounded"
    end

    test "the registry labels B1-04's caps checked at use and claims nothing for C5's" do
      rules = Map.new(Safeguards.limit_rules())

      for field <- @enforced do
        assert Map.fetch!(rules, field).enforced_by,
               "B1-04: #{field} is still registered as not yet enforced"
      end

      for field <- [
            :research_max_search_requests,
            :research_max_page_fetches,
            :research_max_output_tokens,
            :research_max_model_calls,
            :research_target_seconds,
            :research_job_limit_seconds
          ] do
        assert is_nil(Map.fetch!(rules, field).enforced_by),
               "B1-04: #{field} is not enforced by this slice and must stay unclaimed (Q2)"
      end
    end
  end
end

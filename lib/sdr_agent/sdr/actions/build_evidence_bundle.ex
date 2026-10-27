defmodule SdrAgent.SDR.Actions.BuildEvidenceBundle do
  @moduledoc """
  ResearchLeadFlow step "bundle" — normalize evidence, evaluate its quality,
  return the EvidenceBundle (spec §7). Version 2 (B1-04, plan
  `claude-b1-research-draft-plan-r2.md`).

  Before anything else the run's pinned definition must declare this
  version, and the run's settings snapshot must resolve
  (`SdrAgent.SDR.Preconditions`; a fixed `:crash` stop otherwise).

  **Research caps.** The snapshot's three source caps are applied to the
  run's sources in a fixed order — trust `high`, `medium`, `low`, then the
  stable flow order (CRM, website, search results, fetched pages): at most
  `research_max_sources` are kept; each is cut to the longest prefix of
  whole graphemes whose code-point length is within both
  `research_max_source_chars` and what remains of
  `research_max_total_source_chars`; a source with nothing left is dropped;
  only the sent list is indexed. A deterministic `research_caps` Decision
  (rule `sdr.research_caps`, citing the snapshot) records the limits and
  the counts; it carries no source or settings text.

  One model call (Zoi-validated EvidenceExtraction, with the snapshot's
  `research_brief`) proposes claims over the sent sources; for each an LLM
  `evidence_quality` Decision (output pointer `/claims/<i>`) records the
  model's verdict — or `ungrounded` when the deterministic grounding check
  fails: the quote must occur verbatim, wholly inside the text that was
  sent for the cited index (a quote from an unsent suffix or a dropped or
  unknown index is ungrounded). Grounded claims become EvidenceClaims with
  their exact code-point offsets, persisted against the original artifact
  and its full stored content (a sent text is a prefix, so the offsets are
  the same); the accepted ones are the agent's `evidence_ids`. Emits
  `sdr.research.completed`.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_build_evidence_bundle",
    description: "Extract, ground and quality-rate evidence claims.",
    version: "2",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        crm: Zoi.map(),
        company: Zoi.map(),
        search: Zoi.map(),
        pages: Zoi.list(Zoi.map())
      })

  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettingsSnapshot
  alias SdrAgent.Research
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Preconditions
  alias SdrAgent.SDR.Support

  @caps [:research_max_sources, :research_max_source_chars, :research_max_total_source_chars]
  @trust_rank %{high: 0, medium: 1, low: 2}

  # C2* operation snapshot entry `:perform_build_evidence_bundle` (ADR-0005
  # C2* item 2): a direct call owns; under SDR.Action.execute/3 it inherits.
  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id} = params, ctx) do
    OperationSnapshot.enter(:perform_build_evidence_bundle, fn ->
      flow =
        [params.crm, params.company, params.search | params.pages]
        |> Enum.flat_map(& &1.artifacts)
        |> Enum.uniq_by(& &1.id)

      with :ok <- Preconditions.declared(ctx, __MODULE__),
           {:ok, settings} <- Preconditions.settings(ctx),
           {:ok, brief, run, snapshot} <- research_settings(ctx, settings),
           limits = Map.new(@caps, &{&1, RunSettings.ceiling(run, snapshot.limits, &1)}),
           {sent, detail} = select(flow, limits),
           {:ok, %{contact: contact, account: account}} <- Support.lead_context(ctx, lead_id),
           {:ok, _caps} <- caps_decision(ctx, lead_id, snapshot, detail),
           {:ok, output, invocation} <-
             Model.call(ctx, :evidence_extraction, input(account, contact, sent, brief), lead_id),
           {:ok, recorded} <- ground_all(ctx, lead_id, sent, output.claims, invocation) do
        research_completed(ctx, lead_id, recorded)
      end
    end)
  end

  defp research_completed(ctx, lead_id, recorded) do
    accepted = for {:accepted, claim} <- recorded, do: claim.id
    rejected = Enum.count(recorded, &match?({:rejected, _}, &1))

    {:ok, %{ctx.agent_state | phase: :research, evidence_ids: accepted},
     [
       Support.emit("sdr.research.completed", %{
         lead_id: lead_id,
         accepted: length(accepted),
         rejected: rejected,
         ungrounded: Enum.count(recorded, &(&1 == :ungrounded))
       })
     ]}
  end

  # The brief, the run and its snapshot record (for the caps Decision's
  # input ref); any failure is the fixed settings stop.
  defp research_settings(ctx, settings) do
    with {:ok, brief} <- Preconditions.brief(settings),
         {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, %RunSettingsSnapshot{} = snapshot} <-
           Ash.get(RunSettingsSnapshot, run.settings_snapshot_id, actor: ctx.actor) do
      {:ok, brief, run, snapshot}
    else
      _ -> Preconditions.unavailable(ctx)
    end
  end

  # The caps applied to `flow` (sources in flow order): `{sent, detail}`, where
  # `sent` is `[{%{source, content}, index}]` in send order and `detail` the
  # `research_caps` counts.
  defp select(flow, limits) do
    kept =
      flow
      |> Enum.with_index()
      |> Enum.sort_by(fn {source, index} ->
        {Map.get(@trust_rank, source.trust_level, 3), index}
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(limits.research_max_sources)

    {sent, _remaining} =
      Enum.reduce(kept, {[], limits.research_max_total_source_chars}, fn source, {acc, left} ->
        text = grapheme_prefix(source.content, min(limits.research_max_source_chars, left))

        if text == "",
          do: {acc, left},
          else: {[%{source: source, content: text} | acc], left - codepoints(text)}
      end)

    sent = sent |> Enum.reverse() |> Enum.with_index()
    truncated = Enum.count(sent, fn {item, _index} -> item.content != item.source.content end)

    detail = %{
      "limits" => Map.new(limits, fn {field, value} -> {Atom.to_string(field), value} end),
      "sources_available" => length(flow),
      "sources_sent" => length(sent),
      "sources_dropped" => length(flow) - length(sent),
      "sources_truncated" => truncated,
      "source_chars_sent" =>
        sent |> Enum.map(fn {item, _index} -> codepoints(item.content) end) |> Enum.sum()
    }

    {sent, detail}
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

  defp caps_decision(ctx, lead_id, snapshot, detail) do
    capped? = detail["sources_dropped"] > 0 or detail["sources_truncated"] > 0

    Context.decide(
      ctx,
      %{
        kind: :research_caps,
        mode: :deterministic,
        rule_id: "sdr.research_caps",
        rule_version: "1",
        subject_id: lead_id,
        inputs: %{"limits" => detail["limits"], "settings_snapshot_id" => snapshot.id},
        outcome: if(capped?, do: "capped", else: "within_caps"),
        outcome_detail: detail,
        rationale:
          "#{detail["sources_sent"]} of #{detail["sources_available"]} sources sent " <>
            "(#{detail["sources_dropped"]} dropped, #{detail["sources_truncated"]} cut), " <>
            "#{detail["source_chars_sent"]} characters."
      },
      "caps",
      [snapshot]
    )
  end

  defp input(account, contact, sent, brief) do
    %{
      company: %{name: account.name, domain: to_string(account.domain)},
      contact: %{name: "#{contact.first_name} #{contact.last_name}", title: contact.title},
      research_brief: brief,
      sources:
        Enum.map(sent, fn {%{source: source, content: content}, index} ->
          %{
            index: index,
            source_type: source.source_type,
            title: source.title,
            url: source.source_url,
            trust_level: source.trust_level,
            content: content
          }
        end)
    }
  end

  defp ground_all(ctx, lead_id, sent, claims, invocation) do
    by_index = Map.new(sent, fn {item, index} -> {index, item} end)

    claims
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {claim, index}, {:ok, acc} ->
      case ground(ctx, lead_id, Map.get(by_index, claim.source), claim, index, invocation) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp ground(ctx, lead_id, item, claim, index, invocation) do
    # Located in the text that was sent, never in an unsent suffix.
    location = item && locate(item.content, claim.quote)
    source = item && item.source
    outcome = if location, do: claim.quality, else: "ungrounded"

    with {:ok, decision} <-
           Context.decide(
             ctx,
             %{
               kind: :evidence_quality,
               mode: :llm,
               subject_id: lead_id,
               model_invocation_id: invocation.id,
               output_pointer: "/claims/#{index}",
               inputs: %{
                 "research_artifact_id" => source && source.id,
                 "quote_found" => location != nil,
                 "model_quality" => claim.quality
               },
               outcome: outcome,
               rationale: claim.reason,
               confidence: claim.confidence
             },
             "claim:#{index}"
           ) do
      persist(ctx, lead_id, source, claim, location, decision, invocation)
    end
  end

  defp persist(_ctx, _lead_id, _source, _claim, nil, _decision, _invocation),
    do: {:ok, :ungrounded}

  defp persist(ctx, lead_id, source, claim, {from, to}, decision, invocation) do
    attrs = %{
      research_artifact_id: source.id,
      lead_id: lead_id,
      claim: claim.claim,
      quote: claim.quote,
      source_location: %{char_start: from, char_end: to},
      confidence: claim.confidence,
      quality: String.to_existing_atom(claim.quality),
      extraction_decision_id: decision.id,
      model_invocation_id: invocation.id,
      # The original artifact's full stored content (GroundClaim checks its hash).
      content: source.content
    }

    with {:ok, recorded} <- Research.record_claim(attrs, actor: ctx.actor) do
      {:ok, {recorded.quality, recorded}}
    end
  end

  # Code-point offsets (half-open) of the first verbatim occurrence of the
  # quote — code points, not graphemes, as SourceLocation and GroundClaim
  # define them (S5 choice 12): a combining mark or an emoji ZWJ sequence
  # is one grapheme but several code points.
  defp locate(content, quote) do
    case :binary.match(content, quote) do
      {byte_start, _byte_length} ->
        from = content |> binary_part(0, byte_start) |> codepoints()
        {from, from + codepoints(quote)}

      :nomatch ->
        nil
    end
  end

  defp codepoints(text), do: text |> String.codepoints() |> length()
end

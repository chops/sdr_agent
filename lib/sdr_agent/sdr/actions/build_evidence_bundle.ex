defmodule SdrAgent.SDR.Actions.BuildEvidenceBundle do
  @moduledoc """
  ResearchLeadFlow step "bundle" — normalize evidence, evaluate its quality,
  return the EvidenceBundle (spec §7).

  One model call (Zoi-validated EvidenceExtraction) proposes claims over all
  sources of this research; for each proposed claim an LLM `evidence_quality`
  Decision (output pointer `/claims/<i>`) records the model's quality
  verdict — or `ungrounded` when the deterministic grounding check fails:
  the quote must occur verbatim in the cited source's content (S2: a claim
  whose quote is not exactly the cited span is not persisted). Grounded
  claims become EvidenceClaims with their exact code-point offsets; the
  accepted ones are the agent's `evidence_ids`. Emits
  `sdr.research.completed`.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_build_evidence_bundle",
    description: "Extract, ground and quality-rate evidence claims.",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        crm: Zoi.map(),
        company: Zoi.map(),
        search: Zoi.map(),
        pages: Zoi.list(Zoi.map())
      })

  alias SdrAgent.Research
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id} = params, ctx) do
    sources =
      [params.crm, params.company, params.search | params.pages]
      |> Enum.flat_map(& &1.artifacts)
      |> Enum.uniq_by(& &1.id)
      |> Enum.with_index()

    with {:ok, %{contact: contact, account: account}} <- Support.lead_context(ctx, lead_id),
         {:ok, output, invocation} <-
           Model.call(ctx, :evidence_extraction, input(account, contact, sources), lead_id),
         {:ok, recorded} <- ground_all(ctx, lead_id, sources, output.claims, invocation) do
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
  end

  defp input(account, contact, sources) do
    %{
      company: %{name: account.name, domain: to_string(account.domain)},
      contact: %{name: "#{contact.first_name} #{contact.last_name}", title: contact.title},
      sources:
        Enum.map(sources, fn {source, index} ->
          %{
            index: index,
            source_type: source.source_type,
            title: source.title,
            url: source.source_url,
            trust_level: source.trust_level,
            content: source.content
          }
        end)
    }
  end

  defp ground_all(ctx, lead_id, sources, claims, invocation) do
    by_index = Map.new(sources, fn {source, index} -> {index, source} end)

    claims
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {claim, index}, {:ok, acc} ->
      case ground(ctx, lead_id, Map.get(by_index, claim.source), claim, index, invocation) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp ground(ctx, lead_id, source, claim, index, invocation) do
    location = source && locate(source.content, claim.quote)
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
      content: source.content
    }

    with {:ok, recorded} <- Research.record_claim(attrs, actor: ctx.actor) do
      {:ok, {recorded.quality, recorded}}
    end
  end

  # Code-point offsets (half-open) of the first verbatim occurrence of quote.
  defp locate(content, quote) do
    case :binary.match(content, quote) do
      {byte_start, _byte_length} ->
        from = content |> binary_part(0, byte_start) |> String.length()
        {from, from + String.length(quote)}

      :nomatch ->
        nil
    end
  end
end

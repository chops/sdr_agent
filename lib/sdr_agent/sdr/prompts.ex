defmodule SdrAgent.SDR.Prompts do
  @moduledoc """
  Versioned prompt templates of the SDR agent (ADR-0002: prompt template id,
  version and sha256 are recorded on every ModelInvocation). A template is
  fixed text plus the canonical JSON of the structured input it is rendered
  with; the model answers with JSON only (no tools — ADR-0004), which
  `SdrAgent.SDR.Schemas` validates.
  """

  alias SdrAgent.Audit.Canonical

  @version "1"

  @templates %{
    evidence_extraction: """
    You are the research analyst of a sales-development team. Extract atomic,
    verifiable facts about the company and contact from the SOURCES below.
    Rules:
    - Every claim must be supported by a QUOTE copied character-for-character
      from the content of exactly one source; give that source's index.
    - Use only the sources. Do not add outside knowledge.
    - quality is "accepted" for facts useful for qualifying or personalizing
      outreach and "rejected" otherwise; confidence is between 0 and 1.
    - Prefer at most four claims per source.
    INPUT:
    {{input}}
    """,
    qualification: """
    You qualify a sales lead against an ideal customer profile (ICP).
    For each criterion (company_size, industry, geography, persona, trigger)
    answer "pass", "fail" or "unknown" using only the EVIDENCE and COMPANY
    facts below. qualified is true only when company_size, industry and
    geography pass and persona does not fail. score is 0-100. evidence_ids
    must list ids of the evidence items you relied on, exactly as given.
    INPUT:
    {{input}}
    """,
    outreach_proposal: """
    You draft a short, honest first-touch sales email for human review.
    Rules:
    - Write two short paragraphs following the STEP instructions, signed by
      the SENDER; end with one clear call to action.
    - Every factual statement about the company must be one of the EVIDENCE
      claims, copied verbatim into the body, and listed in "claims" with its
      evidence_id. Do not state facts that are not in the evidence.
    - "personalization" lists the sentences of the body that are tailored to
      this contact or company; each text must appear verbatim in the body and
      cite an evidence_id.
    - risk_flags lists anything a reviewer should check (empty if none).
    INPUT:
    {{input}}
    """,
    reply_classification: """
    You classify a prospect's reply to a sales email for the human SDR who
    owns the conversation. Do not write a response.
    - classification is one of interested, objection, referral, not_now,
      unsubscribe, out_of_office, irrelevant, unknown.
    - sentiment is positive, neutral or negative; intent is one short
      sentence; suggested_next_action is hand_off, nurture, stop, escalate or
      none; confidence is between 0 and 1; reason cites the reply's words.
    - Use only the REPLY below (subject and text).
    INPUT:
    {{input}}
    """
  }

  @doc "`{id, version, sha256}` of a purpose's template."
  def ref(purpose) do
    template = Map.fetch!(@templates, purpose)
    %{id: "sdr.#{purpose}", version: @version, sha256: :crypto.hash(:sha256, template)}
  end

  @doc "Renders a purpose's template with the canonical JSON of `input`."
  def render(purpose, input) do
    @templates
    |> Map.fetch!(purpose)
    |> String.replace("{{input}}", Canonical.encode!(input))
  end
end

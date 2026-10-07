defmodule SdrAgent.SDR.Schemas do
  @moduledoc """
  Zoi schemas at every AI boundary of the SDR agent (spec §9). Every model
  output is parsed with one of these by `SdrAgent.AI.ModelProvider` before
  it is used; invalid output is a failed invocation, never coerced (objects
  accept JSON string keys; values are not coerced).

    * `evidence_extraction/0` — claims extracted from the run's sources:
      `source` (index), `claim`, verbatim `quote`, `confidence` 0..1,
      `quality` accepted|rejected, `reason`;
    * `qualification_result/0` — QualificationResult: `qualified`, `score`
      0..100, `criteria` {company_size, industry, geography, persona,
      trigger: pass|fail|unknown}, `confidence` 0..1, `evidence_ids`,
      `reason`;
    * `outreach_proposal/0` — OutreachProposal: `subject`, `body`, `angle`,
      `cta`, `claims` [{claim, evidence_id, confidence}], `personalization`
      [{text, evidence_id}], `risk_flags`, `evidence_ids`;
    * `reply_classification/0` — ReplyAssessment: `classification`,
      `sentiment`, `intent`, `suggested_next_action`, `confidence` 0..1,
      `reason`.

  `ref/1` gives the id, version and canonical sha256 recorded on every
  ModelInvocation (ADR-0002).
  """

  alias SdrAgent.Audit.Canonical

  @version "1"
  @verdict ["pass", "fail", "unknown"]

  @doc "EvidenceExtraction output schema."
  def evidence_extraction do
    object(%{
      claims:
        Zoi.list(
          object(%{
            source: Zoi.integer() |> Zoi.min(0),
            claim: Zoi.string() |> Zoi.min(1),
            quote: Zoi.string() |> Zoi.min(1),
            confidence: unit(),
            quality: Zoi.enum(["accepted", "rejected"]),
            reason: Zoi.string()
          })
        )
    })
  end

  @doc "QualificationResult output schema (spec §9)."
  def qualification_result do
    object(%{
      qualified: Zoi.boolean(),
      score: Zoi.integer() |> Zoi.min(0) |> Zoi.max(100),
      criteria:
        object(%{
          company_size: Zoi.enum(@verdict),
          industry: Zoi.enum(@verdict),
          geography: Zoi.enum(@verdict),
          persona: Zoi.enum(@verdict),
          trigger: Zoi.enum(@verdict)
        }),
      confidence: unit(),
      evidence_ids: Zoi.list(Zoi.string()),
      reason: Zoi.string() |> Zoi.min(1)
    })
  end

  @doc "OutreachProposal output schema (spec §9)."
  def outreach_proposal do
    object(%{
      subject: Zoi.string() |> Zoi.min(1) |> Zoi.max(200),
      body: Zoi.string() |> Zoi.min(1),
      angle: Zoi.string() |> Zoi.min(1),
      cta: Zoi.string() |> Zoi.min(1),
      claims:
        Zoi.list(
          object(%{
            claim: Zoi.string() |> Zoi.min(1),
            evidence_id: Zoi.string() |> Zoi.min(1),
            confidence: unit()
          })
        ),
      personalization:
        Zoi.list(
          object(%{text: Zoi.string() |> Zoi.min(1), evidence_id: Zoi.string() |> Zoi.min(1)})
        ),
      risk_flags: Zoi.list(Zoi.string()),
      evidence_ids: Zoi.list(Zoi.string())
    })
  end

  @doc """
  ReplyAssessment output schema (spec §16; S2 ReplyAssessment): the model
  classifies — it never drafts a response (owner decision) and never decides
  suppression (the deterministic rule does).
  """
  def reply_classification do
    object(%{
      classification:
        Zoi.enum(
          ~w(interested objection referral not_now unsubscribe out_of_office irrelevant unknown)
        ),
      sentiment: Zoi.enum(~w(positive neutral negative)),
      intent: Zoi.string() |> Zoi.min(1) |> Zoi.max(500),
      suggested_next_action: Zoi.enum(~w(hand_off nurture stop escalate none)),
      confidence: unit(),
      reason: Zoi.string() |> Zoi.min(1) |> Zoi.max(1000)
    })
  end

  @doc "The schema for a model purpose."
  def for_purpose(:evidence_extraction), do: evidence_extraction()
  def for_purpose(:reply_classification), do: reply_classification()
  def for_purpose(:qualification), do: qualification_result()
  def for_purpose(:outreach_proposal), do: outreach_proposal()

  @doc "`{id, version, sha256}` of a purpose's schema (canonical JSON Schema hash)."
  def ref(purpose) do
    schema = purpose |> for_purpose() |> Zoi.to_json_schema()
    %{id: "sdr.#{purpose}", version: @version, sha256: Canonical.sha256(schema)}
  end

  @doc "Schema version recorded on Qualification rows."
  def version, do: @version

  defp object(fields), do: Zoi.object(fields, coerce: true)
  defp unit, do: Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)
end

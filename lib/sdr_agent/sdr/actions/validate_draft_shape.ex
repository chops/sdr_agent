defmodule SdrAgent.SDR.Actions.ValidateDraftShape do
  @moduledoc """
  PrepareOutreachFlow step "shape" (deterministic, B1-05; plan
  `claude-b1-research-draft-plan-r2.md` section 3 A2.4): the specified
  syntactic shape rule `sdr.draft_shape` v1 of one proposal. Reasons:

    * `subject_not_single_line` — the subject holds a control character
      (Unicode `Cc`: CR, LF, TAB, BEL, …);
    * `body_contains_url` — the body holds `http://`, `https://` or `www.`
      in any letter case (this slice supplies no booking link, C4-R9).

  It is not detection of every URL spelling and enforces no prose or time
  rule. Records one `draft_shape_validation` Decision bound to the exact
  draft: its inputs name the `draft_proposal` Decision and ModelInvocation
  ids, and its input refs those two records; the outcome detail holds the
  reason codes only — never the subject, the body or settings text.
  `HandOffProposal` hands off only a draft whose bound check passed.

  Version 2 (B1-R1, Codex PR #234 review; SDRAgent v5): after the run's
  pinned definition is checked to declare this version, the rule measures
  the authoritative draft (`SdrAgent.SDR.Support.authoritative_draft/3`):
  this run's `draft_proposal` Decision about the step's lead, citing exactly
  the named ModelInvocation of this run, whose released output is parsed by
  the OutreachProposal schema. The caller's `draft.proposal` is never
  measured, so a disagreeing map changes nothing. A missing or mismatched
  pair stops the run `:crash` with a fixed, content-free reason, and no
  Decision is recorded.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_validate_draft_shape",
    description: "Subject on one line, no link in the body.",
    version: "2",
    schema: Zoi.object(%{lead_id: Zoi.string(), draft: Zoi.map()})

  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Preconditions
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, draft: draft}, ctx) do
    with :ok <- Preconditions.declared(ctx, __MODULE__),
         {:ok, %{decision: decision, invocation: invocation, proposal: proposal}} <-
           Support.authoritative_draft(ctx, lead_id, draft) do
      reasons = reasons(proposal)

      with {:ok, shape} <-
             Context.decide(
               ctx,
               %{
                 kind: :draft_shape_validation,
                 mode: :deterministic,
                 rule_id: "sdr.draft_shape",
                 rule_version: "1",
                 subject_id: lead_id,
                 inputs: %{
                   "draft_proposal_decision_id" => decision.id,
                   "model_invocation_id" => invocation.id
                 },
                 outcome: if(reasons == [], do: "passed", else: "rejected"),
                 outcome_detail: %{"reasons" => reasons}
               },
               "validate",
               [decision, invocation]
             ) do
        {:ok, %{passed: reasons == [], decision_id: shape.id}}
      end
    end
  end

  @doc "The shape reasons of a proposal (`[]` when it passes)."
  def reasons(%{subject: subject, body: body}) do
    [
      Regex.match?(~r/\p{Cc}/u, subject) && "subject_not_single_line",
      Regex.match?(~r/https?:\/\/|www\./iu, body) && "body_contains_url"
    ]
    |> Enum.filter(& &1)
  end
end

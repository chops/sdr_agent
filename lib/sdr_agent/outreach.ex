defmodule SdrAgent.Outreach do
  @moduledoc """
  Outreach bounded context (S2): what may be sent, to whom, on whose
  authority — and who must never be contacted.

  Resources: `Draft`, `DraftRevision`, `RevisionCitation`, `Approval`,
  `Suppression` (S8a); `DeliveryOperation`, `DeliveryReceipt`,
  `SendQuotaDay` (S8b, the outbox driven by `SdrAgent.Outreach.Delivery`
  and its workers); `Reply` (S9, written by the signed provider webhook,
  `SdrAgent.Outreach.Webhooks`, which also records delivery outcomes and the
  deterministic unsubscribe, bounce and complaint suppressions). Outreach is the highest domain: it holds FKs to Research
  (cited claims), Sales (lead, enrollment, step, campaign, contact), Agents
  (runs, decisions, invocations), Accounts (operators) and Audit (tenant),
  and stops Sales leads/enrollments only as the side effect of a suppression
  (`SdrAgent.Sales.Checks.SuppressionContext`). The agent plane calls it
  (draft hand-off, suppression lookup); it calls no agent code.

  Public API (every function takes `actor:`; writes run through
  `SdrAgent.Audit.Guard`; the S2 *guarded actions* — draft edit, approval
  approve/reject/revoke, suppression create, delivery `cancel_retry` — audit
  every denial):

    * drafts — `propose_draft/2` (AGT, the hand-off), `edit_draft/3` (ADM,
      REV), `list_review_queue/1`;
    * approval — `approve/3`, `reject/3` (ADM, REV; the reviewed
      `draft_revision_id` and its hex `content_sha256`), `revoke/2`;
    * suppression — `suppress/2` (ADM, manual), `seed_suppression/2` (SEED,
      dev/test), `matching_suppressions/2` (the email's own and its domain's
      suppressions);
    * delivery — `cancel_retry/2` (ADM, REV), `record_receipt/2` (DLV, REC;
      the capture adapter's receipt);
    * reads (tenant-scoped) — `fetch/3`, `list_records/2`.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query

  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.Suppression

  resources do
    resource SdrAgent.Outreach.Draft
    resource SdrAgent.Outreach.DraftRevision
    resource SdrAgent.Outreach.RevisionCitation
    resource SdrAgent.Outreach.Approval
    resource SdrAgent.Outreach.Suppression
    resource SdrAgent.Outreach.DeliveryOperation
    resource SdrAgent.Outreach.DeliveryReceipt
    resource SdrAgent.Outreach.SendQuotaDay
    resource SdrAgent.Outreach.Reply
  end

  @doc """
  AGT: creates the hand-off draft with its agent revision 1 (`subject`,
  `body_text`, `angle`, `cta`, `risk_flags`, `decision_id`,
  `model_invocation_id`, `citations: [%{evidence_claim_id, kind, text,
  confidence}]`) for `lead_id`, `enrollment_id`, `sequence_step_id`,
  `campaign_id`, `recipient_contact_id`, `origin_agent_run_id`.
  """
  def propose_draft(attrs, opts) do
    GuardedCall.create(Draft, :propose, attrs, subject(opts, attrs, :lead_id))
  end

  @doc "ADM, REV: a human revision (`subject`, `body_text`, optional `angle`, `cta`) of a draft pending review."
  def edit_draft(draft, attrs, opts),
    do: GuardedCall.update(draft, :edit, attrs, guarded(opts))

  @doc "Drafts awaiting review, oldest first."
  def list_review_queue(opts) do
    opts
    |> Keyword.put(:action, :review_queue)
    |> then(&GuardedCall.read_query(Draft, &1))
    |> Ash.read()
  end

  @doc """
  ADM, REV: grants `draft`'s current revision. `binding`: the reviewed
  `draft_revision_id` and its hex `content_sha256`; anything else is stale.
  """
  def approve(draft, binding, opts) do
    attrs =
      binding
      |> Map.new()
      |> Map.take([:draft_revision_id, :content_sha256])
      |> Map.put(:draft_id, draft.id)

    GuardedCall.create(Approval, :approve, attrs, guarded(opts, draft.id))
  end

  @doc "ADM, REV: rejects `draft`'s current revision (`draft_revision_id`, `content_sha256`, `reason`)."
  def reject(draft, binding, opts) do
    attrs =
      binding
      |> Map.new()
      |> Map.take([:draft_revision_id, :content_sha256, :reason])
      |> Map.put(:draft_id, draft.id)

    GuardedCall.create(Approval, :reject, attrs, guarded(opts, draft.id))
  end

  @doc "ADM, REV: revokes a granted approval; its draft returns to review."
  def revoke(approval, opts), do: GuardedCall.update(approval, :revoke, %{}, guarded(opts))

  @doc "ADM: suppresses an email or domain (`scope`, `value`); idempotent."
  def suppress(attrs, opts), do: GuardedCall.create(Suppression, :manual, attrs, guarded(opts))

  @doc "SEED (dev/test only): a fixture suppression (`id`, `scope`, `value`); idempotent."
  def seed_suppression(attrs, opts), do: GuardedCall.create(Suppression, :seed, attrs, opts)

  @doc "Suppressions of `email` itself or of its domain (normalised), oldest first."
  def matching_suppressions(email, opts) do
    actor = Keyword.get(opts, :actor)
    email = email |> to_string() |> String.trim() |> String.downcase()

    Suppression
    |> Ash.Query.for_read(:matching, %{email: email}, actor: actor)
    |> then(fn query ->
      case actor do
        %{tenant_id: tenant_id} when is_binary(tenant_id) ->
          Ash.Query.filter(query, tenant_id == ^tenant_id)

        _ ->
          query
      end
    end)
    |> Ash.read()
  end

  @doc "ADM, REV: stops a delivery waiting for a retry (failed_retryable → cancelled); its draft is cancelled."
  def cancel_retry(delivery, opts),
    do: GuardedCall.update(delivery, :cancel_retry, %{}, guarded(opts))

  @doc "DLV, REC: records a delivery receipt; idempotent per delivery and kind."
  def record_receipt(attrs, opts),
    do:
      GuardedCall.create(
        DeliveryReceipt,
        :record,
        attrs,
        subject(opts, attrs, :delivery_operation_id)
      )

  @doc "Reads one Outreach record of `resource` by id in the actor's tenant."
  def fetch(resource, id, opts), do: GuardedCall.get(resource, id, opts)

  @doc "Lists `resource` records in the actor's tenant (`filter:`, `sort:` options)."
  def list_records(resource, opts), do: GuardedCall.list(resource, opts)

  defp guarded(opts, subject_id \\ nil) do
    opts = Keyword.put(opts, :guarded?, true)
    if subject_id, do: Keyword.put(opts, :subject_id, subject_id), else: opts
  end

  defp subject(opts, attrs, key), do: Keyword.put(opts, :subject_id, Map.get(Map.new(attrs), key))
end

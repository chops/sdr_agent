defmodule SdrAgent.Outreach.Delivery do
  @moduledoc """
  The outbox delivery path (spec §14): what the delivery, reconciliation and
  sweeper jobs run. Every step is a transaction that takes its row locks in
  the Outreach lock order — enrollment → draft → delivery → approval →
  campaign → contact → quota day — *before* its first audit append (the chain-head lock), so no
  step ever waits for a row while holding the chain head.

    * `attempt/2` (DLV) — the send gate, as one deterministic `send_gate`
      Decision: the approval is still granted (first claim) or consumed by
      this delivery (retry); revision hash and recipient email still match;
      the contact is active and neither its email nor its domain is
      suppressed; enrollment and campaign are active; the footer is known;
      outside quiet hours (campaign time zone); and, on the first claim, one
      SendQuotaDay unit (`quota_check` Decision). Quiet hours and the cap
      *defer* (`not_before`, a new job); anything else *cancels* the delivery,
      invalidates a granted approval and cancels the draft. On a pass, the
      claim (pending | failed_retryable → attempting), the approval's
      consumption and the rendered message commit together; the message is
      then handed to the adapter outside any transaction and the outcome is
      recorded: accepted (receipt, draft sent, enrollment advanced, follow-up
      scheduled), retryable (bounded, backoff), permanent, or unknown
      (reconciliation job) — `record/4`.
    * `reconcile/2` (REC) — an unknown delivery asks the adapter what it
      accepted (`delivery_reconciliation` Decision): accepted → as above;
      nothing → a retry (or failed_permanent at max attempts). Never a blind
      resend.
    * `sweep/1` (REC) — claims left `attempting` longer than
      `Compliance.stale_after_seconds/0` (a crash after the hand-off) become
      unknown and go to reconciliation.

  The adapter is always `SdrAgent.Outreach.Delivery.CaptureAdapter`
  (`adapter/0`; not configurable).
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Outreach.Delivery.CaptureAdapter
  alias SdrAgent.Outreach.Delivery.Message
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Outreach.SendQuotaDay
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.Sales.LocalTime

  @claimable [:pending, :failed_retryable]
  @invalidated %{
    content_mismatch: :newer_revision,
    recipient_changed: :recipient_changed,
    recipient_inactive: :recipient_changed,
    suppressed: :suppressed
  }

  @doc "The delivery adapter: always the local capture adapter (ADR-0001)."
  def adapter, do: CaptureAdapter

  ## Attempt

  @doc "Runs the send gate for delivery `id` and, if it passes, delivers. `:ok` or `{:snooze, s}`."
  def attempt(id, tenant_id) do
    dlv = Actor.system(:delivery_worker, tenant_id)

    case transaction(fn -> gate(id, tenant_id, dlv) end) do
      {:ok, {:claimed, op, rendered}} -> deliver(op, rendered, dlv)
      {:ok, {:snooze, seconds}} -> {:snooze, seconds}
      {:ok, _done} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp gate(id, tenant_id, dlv) do
    with %{state: state} = peek when state in @claimable <- read(DeliveryOperation, id, tenant_id),
         enrollment <- lock(Sales.CampaignEnrollment, peek.enrollment_id, tenant_id, "FOR SHARE"),
         _draft <- lock(Draft, peek.draft_id, tenant_id),
         %{state: state} = op when state in @claimable <- lock(DeliveryOperation, id, tenant_id) do
      if op.not_before && DateTime.compare(op.not_before, Clock.utc_now()) == :gt,
        do: {:snooze, max(DateTime.diff(op.not_before, Clock.utc_now()), 1)},
        else: evaluate(op, enrollment, tenant_id, dlv)
    else
      _ -> :done
    end
  end

  # Every row the verdict depends on is locked before the first append
  # (review #14 MF2), in the Outreach order enrollment → draft → delivery →
  # approval → campaign → contact → quota day: a change to any of them either
  # committed before (and is read here) or waits for this evaluation.
  defp evaluate(op, enrollment, tenant_id, dlv) do
    approval = lock(Approval, op.approval_id, tenant_id)
    campaign = lock(Sales.Campaign, op.campaign_id, tenant_id, "FOR SHARE")
    contact = lock(Sales.Contact, op.recipient_contact_id, tenant_id, "FOR SHARE")
    first? = op.attempt_count == 0
    day = if first?, do: open_day(tenant_id, dlv)

    facts =
      facts(
        op,
        approval,
        %{enrollment: enrollment, campaign: campaign, contact: contact},
        tenant_id
      )

    {verdict, detail} = verdict(op, approval, facts, day, first?)
    {:ok, gate} = decide(dlv, op, :send_gate, "outreach.send_gate", verdict, facts.inputs, detail)

    case verdict do
      "pass" -> claim(op, approval, facts, day, gate, dlv)
      "defer_quiet_hours" -> defer(op, gate, detail.not_before, dlv)
      "defer_quota" -> defer_quota(op, day, gate, detail.not_before, dlv)
      "refuse" -> refuse(op, approval, detail.reason, gate, dlv)
    end
  end

  # Everything the gate decides on, from the locked rows (the revision is
  # immutable). The message is rendered here so a retry whose bytes would
  # differ from the first attempt's is refused, never sent (review #14).
  defp facts(op, approval, locked, tenant_id) do
    %{enrollment: enrollment, campaign: campaign, contact: contact} = locked
    revision = read(DraftRevision, op.draft_revision_id, tenant_id)
    email = String.downcase(to_string(contact.email))
    suppressions = suppressions(email, tenant_id)
    now = Clock.utc_now()
    rendered = render(op, revision, campaign)

    %{
      revision: revision,
      rendered: rendered,
      rendered_sha256: rendered && :crypto.hash(:sha256, rendered),
      contact: contact,
      campaign: campaign,
      now: now,
      quiet?:
        LocalTime.quiet?(
          now,
          campaign.timezone,
          campaign.quiet_hours_start,
          campaign.quiet_hours_end
        ),
      inputs: %{
        "approval" => %{"id" => approval.id, "status" => to_string(approval.status)},
        "revision_sha256" => hex(revision.content_sha256),
        "bound_sha256" => hex(op.revision_content_sha256),
        "approved_sha256" => hex(approval.revision_content_sha256),
        "bound_email" => to_string(op.recipient_email),
        "contact_email" => email,
        "contact_status" => to_string(contact.status),
        "suppression_ids" => Enum.map(suppressions, & &1.id),
        "enrollment_status" => to_string(enrollment.status),
        "campaign_status" => to_string(campaign.status),
        "footer_template_version" => campaign.footer_template_version,
        "timezone" => campaign.timezone,
        "local_time" => now |> LocalTime.local_time(campaign.timezone) |> Time.to_iso8601(),
        "quiet_hours" => [
          Time.to_iso8601(campaign.quiet_hours_start),
          Time.to_iso8601(campaign.quiet_hours_end)
        ],
        "attempt" => op.attempt_count + 1
      }
    }
  end

  defp verdict(op, approval, facts, day, first?) do
    case refusal(op, approval, facts, first?) do
      nil -> timing(facts, day, first?)
      reason -> {"refuse", %{reason: reason}}
    end
  end

  # The first failing check, in order, or nil. A first claim needs a granted
  # approval; a retry, the approval this delivery already consumed.
  defp refusal(op, approval, facts, first?) do
    i = facts.inputs
    expected = if first?, do: :granted, else: :consumed

    [
      approval_not_granted: approval.status != expected,
      content_mismatch:
        i["revision_sha256"] != i["bound_sha256"] or i["bound_sha256"] != i["approved_sha256"],
      recipient_changed: i["contact_email"] != String.downcase(i["bound_email"]),
      recipient_inactive: facts.contact.status != :active,
      suppressed: i["suppression_ids"] != [],
      enrollment_inactive: i["enrollment_status"] != "active",
      campaign_inactive: i["campaign_status"] != "active",
      unsupported_footer: facts.campaign.footer_template_version not in Message.footer_versions(),
      rendered_drift: drifted?(op, facts)
    ]
    |> Enum.find_value(fn {reason, failed?} -> failed? && reason end)
  end

  defp drifted?(%{rendered_sha256: nil}, _facts), do: false
  defp drifted?(%{rendered_sha256: sha}, %{rendered_sha256: rendered}), do: sha != rendered

  defp render(op, revision, campaign) do
    if campaign.footer_template_version in Message.footer_versions() do
      Message.render(%{
        operation: op,
        revision: revision,
        campaign: campaign,
        at: op.requested_at
      })
    end
  end

  defp timing(facts, day, first?) do
    campaign = facts.campaign

    cond do
      facts.quiet? ->
        {"defer_quiet_hours",
         %{
           not_before:
             LocalTime.next_wall_time(facts.now, campaign.timezone, campaign.quiet_hours_end)
         }}

      first? and day.consumed >= day.cap ->
        {"defer_quota",
         %{not_before: LocalTime.next_wall_time(facts.now, day.timezone, ~T[00:00:00])}}

      true ->
        {"pass", %{}}
    end
  end

  defp claim(op, approval, facts, day, gate, dlv) do
    rendered = facts.rendered

    with {:ok, quota_date} <- consume(day, op, dlv),
         {:ok, payload} <- Audit.put_payload(rendered, "message/rfc822", actor: dlv),
         {:ok, claimed} <-
           update(op, :claim, dlv, %{
             last_decision_id: gate.id,
             send_quota_date: quota_date,
             rendered_sha256: payload.sha256,
             footer_template_version: facts.campaign.footer_template_version
           }),
         {:ok, _approval} <- consume_approval(approval, dlv) do
      {:claimed, claimed, rendered}
    end
  end

  # Retries never consume a second unit (the first claim's date stays).
  defp consume(nil, op, _dlv), do: {:ok, op.send_quota_date}

  defp consume(day, op, dlv) do
    with {:ok, day} <- update(day, :consume, dlv, %{}),
         {:ok, _} <- quota_decision(dlv, op, "reserved", day) do
      {:ok, day.local_date}
    end
  end

  defp consume_approval(%{status: :granted} = approval, dlv),
    do: update(approval, :consume, dlv, %{})

  defp consume_approval(approval, _dlv), do: {:ok, approval}

  defp defer(op, gate, not_before, dlv) do
    with {:ok, op} <-
           update(op, :defer, dlv, %{not_before: not_before, last_decision_id: gate.id}),
         {:ok, _job} <- enqueue_attempt(op, not_before),
         do: :deferred
  end

  defp defer_quota(op, day, gate, not_before, dlv) do
    with {:ok, _} <- quota_decision(dlv, op, "exhausted", day),
         do: defer(op, gate, not_before, dlv)
  end

  defp refuse(op, approval, reason, gate, dlv) do
    error = %{"reason" => Atom.to_string(reason)}

    with {:ok, _op} <- update(op, :cancel, dlv, %{last_error: error, last_decision_id: gate.id}),
         :ok <- invalidate(approval, reason, dlv),
         :ok <- move_draft(op.draft_id, op.tenant_id, :cancel, "delivery refused: #{reason}", dlv),
         do: :refused
  end

  defp invalidate(%{status: :granted} = approval, reason, dlv) do
    attrs = %{invalidated_reason: Map.get(@invalidated, reason, :campaign_closed)}

    case update(approval, :invalidate, dlv, attrs, InternalWrite.context()) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp invalidate(_approval, _reason, _dlv), do: :ok

  ## Hand-off and outcome

  defp deliver(op, rendered, dlv) do
    outcome = adapter().deliver(op, rendered, actor: dlv)
    {:ok, _} = transaction(fn -> record(op.id, op.tenant_id, outcome, dlv) end)
    :ok
  end

  @doc false
  # Records the adapter's outcome for a claimed (attempting) delivery.
  def record(id, tenant_id, outcome, dlv) do
    {enrollment, op} = lock_for_outcome(id, tenant_id)

    if op.state == :attempting,
      do: record_outcome(outcome, enrollment, op, dlv),
      else: :done
  end

  defp record_outcome({:ok, %{provider_message_id: pmid}}, enrollment, op, dlv) do
    with {:ok, op} <- update(op, :record_accepted, dlv, %{provider_message_id: pmid}),
         {:ok, _} <- receipt(op, :accepted, dlv),
         do: after_accept(op, enrollment, dlv)
  end

  defp record_outcome({:error, {:retryable, reason}}, _enrollment, op, dlv) do
    if op.attempt_count < op.max_attempts do
      not_before = DateTime.add(Clock.utc_now(), backoff(op.attempt_count), :second)

      with {:ok, op} <-
             update(op, :record_retryable, dlv, %{
               last_error: error(reason),
               not_before: not_before
             }),
           {:ok, _job} <- enqueue_attempt(op, not_before),
           do: :retry_scheduled
    else
      fail(op, reason, dlv)
    end
  end

  defp record_outcome({:error, {:permanent, reason}}, _enrollment, op, dlv),
    do: fail(op, reason, dlv)

  defp record_outcome({:error, {:unknown, reason}}, _enrollment, op, dlv) do
    with {:ok, op} <- update(op, :record_unknown, dlv, %{last_error: error(reason)}),
         {:ok, _job} <- enqueue_reconcile(op),
         do: :reconciliation_scheduled
  end

  defp fail(op, reason, dlv) do
    with {:ok, op} <- update(op, :record_failed, dlv, %{last_error: error(reason)}),
         :ok <- move_draft(op.draft_id, op.tenant_id, :mark_failed, nil, dlv),
         do: :failed
  end

  # The draft is sent; the enrollment (if still active) moves to the
  # delivered step and the next step's follow-up job is scheduled.
  defp after_accept(op, enrollment, actor) do
    draft = read(Draft, op.draft_id, op.tenant_id)
    step = read(Sales.SequenceStep, draft.sequence_step_id, op.tenant_id)

    with :ok <- move_draft(op.draft_id, op.tenant_id, :mark_sent, nil, actor),
         {:ok, _} <- advance(enrollment, step, op, actor),
         do: :accepted
  end

  defp advance(%{status: :active} = enrollment, step, op, actor) do
    with {:ok, advanced} <-
           Sales.advance_enrollment(
             enrollment,
             %{step_position: step.position, accepted_at: op.accepted_at},
             actor: actor
           ) do
      schedule_followup(advanced)
    end
  end

  defp advance(enrollment, _step, _op, _actor), do: {:ok, enrollment}

  # The scheduler's job (`SdrAgent.SDR.FollowupWorker`, agent plane) is named
  # by string: Outreach never depends on the agent plane at compile time.
  defp schedule_followup(%{next_step_due_at: nil} = enrollment), do: {:ok, enrollment}

  defp schedule_followup(enrollment) do
    %{
      "enrollment_id" => enrollment.id,
      "tenant_id" => enrollment.tenant_id,
      "step_position" => enrollment.current_step_position
    }
    |> Oban.Job.new(
      worker: "SdrAgent.SDR.FollowupWorker",
      queue: :followup,
      scheduled_at: enrollment.next_step_due_at,
      max_attempts: 3
    )
    |> Oban.insert()
  end

  ## Reconciliation

  @doc "REC: resolves an unknown delivery `id` from what the adapter accepted. Returns `:ok`."
  def reconcile(id, tenant_id) do
    rec = Actor.system(:reconciler, tenant_id)

    {:ok, _} =
      transaction(fn ->
        {enrollment, op} = lock_for_outcome(id, tenant_id)
        if op.state == :unknown, do: resolve(enrollment, op, rec), else: :done
      end)

    :ok
  end

  defp resolve(enrollment, op, rec) do
    lookup = adapter().lookup(op, actor: rec)
    outcome = if match?({:accepted, _}, lookup), do: "accepted", else: "not_accepted"

    inputs = %{
      "idempotency_key" => op.idempotency_key,
      "lookup" => inspect(lookup),
      "attempt_count" => op.attempt_count,
      "max_attempts" => op.max_attempts
    }

    {:ok, decision} =
      decide(
        rec,
        op,
        :delivery_reconciliation,
        "outreach.delivery_reconciliation",
        outcome,
        inputs,
        %{}
      )

    resolve_as(lookup, decision, enrollment, op, rec)
  end

  defp resolve_as({:accepted, pmid}, decision, enrollment, op, rec) do
    with {:ok, op} <-
           update(op, :reconcile_accepted, rec, %{
             provider_message_id: pmid,
             last_decision_id: decision.id
           }),
         {:ok, _} <- receipt(op, :reconciled, rec),
         do: after_accept(op, enrollment, rec)
  end

  defp resolve_as(
         :not_found,
         decision,
         _enrollment,
         %{attempt_count: n, max_attempts: max} = op,
         rec
       )
       when n < max do
    now = Clock.utc_now()

    with {:ok, op} <-
           update(op, :reconcile_retryable, rec, %{last_decision_id: decision.id, not_before: now}),
         {:ok, _job} <- enqueue_attempt(op, now),
         do: :retry_scheduled
  end

  defp resolve_as(:not_found, decision, _enrollment, op, rec) do
    with {:ok, op} <-
           update(op, :reconcile_failed, rec, %{
             last_decision_id: decision.id,
             last_error: error(:not_accepted_after_max_attempts)
           }),
         :ok <- move_draft(op.draft_id, op.tenant_id, :mark_failed, nil, rec),
         do: :failed
  end

  @doc "REC: marks claims stale beyond `Compliance.stale_after_seconds/0` unknown. Returns `:ok`."
  def sweep(tenant_id) do
    rec = Actor.system(:reconciler, tenant_id)
    before = DateTime.add(Clock.utc_now(), -Compliance.stale_after_seconds(), :second)

    {:ok, stale} =
      DeliveryOperation
      |> Ash.Query.for_read(:stale_attempts, %{before: before}, actor: rec)
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read()

    Enum.each(
      stale,
      &({:ok, _} = transaction(fn -> sweep_one(&1.id, tenant_id, before, rec) end))
    )
  end

  defp sweep_one(id, tenant_id, before, rec) do
    op = lock(DeliveryOperation, id, tenant_id)

    if op.state == :attempting and DateTime.compare(op.attempting_at, before) == :lt do
      with {:ok, op} <- update(op, :record_unknown, rec, %{last_error: error(:stale_attempt)}),
           {:ok, _job} <- enqueue_reconcile(op),
           do: :swept
    else
      :done
    end
  end

  ## Helpers

  defp lock_for_outcome(id, tenant_id) do
    peek = read(DeliveryOperation, id, tenant_id)
    enrollment = lock(Sales.CampaignEnrollment, peek.enrollment_id, tenant_id)
    _draft = lock(Draft, peek.draft_id, tenant_id)
    {enrollment, lock(DeliveryOperation, id, tenant_id)}
  end

  defp open_day(tenant_id, dlv) do
    zone = Compliance.timezone()
    date = LocalTime.local_date(Clock.utc_now(), zone)

    {:ok, _day} =
      SendQuotaDay
      |> Ash.Changeset.for_create(
        :open,
        %{local_date: date, timezone: zone, cap: Compliance.daily_send_cap()},
        actor: dlv
      )
      |> Ash.create()

    SendQuotaDay
    |> Ash.Query.filter(tenant_id == ^tenant_id and local_date == ^date)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  defp quota_decision(dlv, op, outcome, day) do
    decide(
      dlv,
      op,
      :quota_check,
      "outreach.quota_check",
      outcome,
      %{
        "local_date" => Date.to_iso8601(day.local_date),
        "timezone" => day.timezone,
        "cap" => day.cap,
        "consumed" => day.consumed
      },
      %{}
    )
  end

  defp decide(actor, op, kind, rule_id, outcome, inputs, detail) do
    Agents.record_decision(
      %{
        kind: kind,
        mode: :deterministic,
        rule_id: rule_id,
        rule_version: "1",
        subject_resource: inspect(DeliveryOperation),
        subject_id: op.id,
        inputs: inputs,
        outcome: outcome,
        outcome_detail: Map.new(detail, fn {k, v} -> {to_string(k), detail_value(v)} end),
        idempotency_key: "#{kind}:#{op.id}:#{Ash.UUIDv7.generate()}"
      },
      actor: actor
    )
  end

  defp detail_value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp detail_value(value) when is_atom(value), do: Atom.to_string(value)
  defp detail_value(value), do: value

  defp receipt(op, kind, actor) do
    DeliveryReceipt
    |> Ash.Changeset.for_create(
      :record,
      %{
        delivery_operation_id: op.id,
        idempotency_key: op.idempotency_key,
        kind: kind,
        provider: op.provider,
        provider_message_id: op.provider_message_id,
        rendered_sha256: op.rendered_sha256
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp move_draft(draft_id, tenant_id, action, reason, actor) do
    attrs = if reason, do: %{status_reason: reason}, else: %{}

    case update(read(Draft, draft_id, tenant_id), action, actor, attrs, InternalWrite.context()) do
      {:ok, _draft} -> :ok
      error -> error
    end
  end

  defp enqueue_attempt(op, at) do
    %{"delivery_operation_id" => op.id, "tenant_id" => op.tenant_id}
    |> SdrAgent.Outreach.DeliveryWorker.new(scheduled_at: at)
    |> Oban.insert()
  end

  defp enqueue_reconcile(op) do
    %{"delivery_operation_id" => op.id, "tenant_id" => op.tenant_id}
    |> SdrAgent.Outreach.ReconcileWorker.new()
    |> Oban.insert()
  end

  defp suppressions(email, tenant_id) do
    Suppression
    |> Ash.Query.for_read(:matching, %{email: email}, authorize?: false)
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp update(record, action, actor, attrs, context \\ %{}) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor, context: context)
    |> Ash.update()
  end

  # Internal reads and row locks of the rows a delivery step moves; nothing
  # read here is returned to a caller.
  defp read(resource, id, tenant_id) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp lock(resource, id, tenant_id, mode \\ :for_update) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(mode)
    |> Ash.read_one!(authorize?: false)
  end

  defp transaction(fun) do
    Audit.transaction(fn ->
      case fun.() do
        {:error, error} -> Repo.rollback(error)
        value -> value
      end
    end)
  end

  defp backoff(attempt), do: 60 * Integer.pow(2, max(attempt - 1, 0))

  defp error(reason), do: %{"reason" => to_string(reason)}

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end

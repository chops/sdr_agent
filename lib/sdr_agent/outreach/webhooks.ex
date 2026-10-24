defmodule SdrAgent.Outreach.Webhooks do
  @moduledoc """
  The simulated provider webhook (`capture_sim`; spec §16 "Webhook → verify
  signature → persist WebhookEvent → dedupe → persist Reply → cancel
  followups → Oban → sdr.reply.received"; checklist 4.3). Runs as the
  webhook ingestor (WHK) of the singleton tenant.

    * `ingest/3` — the HTTP request's raw bytes are stored as a Payload
      first; the signature is verified (`SdrAgent.Outreach.Webhooks.Signature`);
      a valid event becomes a `received` WebhookEvent plus its `integration`
      job in one transaction (a duplicate valid event: no row, no job,
      `webhook.duplicate_ignored`); any other verdict becomes a `rejected`
      event with a `signature_invalid` Failure and is never processed.
    * `process/2` — the job: under the event's row lock, a `received` event
      is decoded, validated (Zoi) and applied in one transaction, then
      marked `processed`; a payload that does not validate or names nothing
      known marks it `failed` with a `validation_error` Failure (operator
      attention). Reprocessing is a no-op — except a `failed` event with an
      unconsumed operator retry request (S13b, `Outreach.retry_webhook/2`):
      success marks it `processed` (resolving its Failure), another failure
      consumes the request (`:record_retry_failed`, no new Failure).

  Event types: `reply` (match → `SdrAgent.Outreach.Reply`, the
  deterministic `unsubscribe_rule` Decision and, when it says so, an
  `unsubscribe_reply` Suppression; a matched reply is handed to the agent
  plane through `SdrAgent.Outreach.ReplyIntake` in the same transaction,
  or, when the agent definition is unavailable, the reply phase commits
  alone and a later attempt of the same event resumes only the hand-off,
  C3-02 section 6.7), `unsubscribe` (the signed footer link: `Unsubscribe.verify/3` →
  `unsubscribe_link` Suppression), `delivered` and `bounce` (accepted →
  delivered | bounced with a receipt; a bounce always suppresses the
  recipient as `hard_bounce`), `complaint` (`complaint` Suppression).

  Every row lock is taken before the first audit append of the processing
  transaction (`SdrAgent.Outreach.Locks`): event row, then leads →
  enrollments → drafts → deliveries → approvals.

  Identity keys (C3-02 G6; plan r8 sections 6.2 and 16.5; ADR-0009 C3-02
  amendment): after its own WebhookEvent row (the only lock allowed before
  it), each path takes one pass (`SdrAgent.Audit.IdentityKeys.pass/2`)
  before any lookup, row lock or write; the nested `:from_webhook`
  Suppression only requires its key held. A reply passes
  `{reply-message: m, email: from}`, where `m` is the represented
  Message-ID: the payload value under `Reply.message_id`'s own Ash type and
  constraints (trimmed, case kept), derived once and used for the key, the
  stored-reply check and the Reply; an empty or unrepresentable one is the
  fixed schema refusal before any pass. Both the first processing and a
  resumed hand-off take the same pass. A matched reply then reads its match
  unlocked, locks the targets and recomputes the match, which must be
  unchanged (otherwise `{:error, :reply_match_changed}`, the whole attempt
  rolled back). An unsubscribe link passes `{email}` of the contact it
  read and re-reads it (a changed or missing contact is `{:error,
  :conflict}`); a bounce or complaint passes `{email}` of the delivery's
  stored recipient. A delivered event takes no key.
  """

  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Audit.IdentityKeys
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Operations.WebhookRetryLedger
  alias SdrAgent.Outreach.Changes.NormalizeSuppression
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.Locks
  alias SdrAgent.Outreach.Reply
  alias SdrAgent.Outreach.ReplyIntake
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Outreach.Unsubscribe
  alias SdrAgent.Outreach.UnsubscribeRule
  alias SdrAgent.Outreach.Webhooks.Signature
  alias SdrAgent.Outreach.WebhookWorker
  alias SdrAgent.Repo
  alias SdrAgent.Sales

  @types Map.new(WebhookEvent.event_types(), &{Atom.to_string(&1), &1})
  @header_allowlist ~w(content-type user-agent x-sdr-key-id x-sdr-timestamp x-sdr-signature)
  @message_host "@sdr.example.test>"
  @handoff_pending "reply hand-off pending: agent definition unavailable"
  @reply_schema_refusal "payload does not match the reply schema"
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  ## Ingest

  @doc """
  Verifies and records one webhook request: `type` (path segment), the raw
  body bytes and the request headers (lowercase names). Returns
  `{:ok, %{status: :accepted | :duplicate | :rejected, event: event}}` or
  `{:error, :unknown_event_type}` (nothing stored).
  """
  def ingest(type, raw_body, headers) when is_binary(raw_body) and is_map(headers) do
    with {:ok, event_type} <- Map.fetch(@types, type) |> ok_or(:unknown_event_type),
         {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      whk = Actor.system(:webhook_ingestor, tenant_id)
      {verdict, meta} = Signature.verify(headers, raw_body, Clock.utc_now())
      verdict = bind_type(verdict, raw_body, type)

      attrs = %{
        provider: :capture_sim,
        event_type: event_type,
        external_event_id: external_id(raw_body),
        signature_key_id: meta.key_id,
        signed_timestamp: meta.signed_at,
        raw_body_sha256: :crypto.hash(:sha256, raw_body),
        headers: Map.new(Map.take(headers, @header_allowlist), fn {k, v} -> {k, cap(v)} end)
      }

      transaction(fn -> record(verdict, attrs, raw_body, headers, whk) end)
    end
  end

  defp record(verdict, attrs, raw_body, headers, whk) do
    content_type = Map.get(headers, "content-type", "application/octet-stream")

    with {:ok, _payload} <- Audit.put_payload(raw_body, cap(content_type), actor: whk) do
      if verdict == :valid,
        do: receive_valid(attrs, raw_body, whk),
        else: reject(verdict, attrs, whk)
    end
  end

  defp receive_valid(attrs, raw_body, whk) do
    with {:ok, event} <- create(WebhookEvent, :receive, attrs, whk) do
      if Ash.Resource.get_metadata(event, :sdr_replayed),
        do: %{status: :duplicate, event: event},
        else: enqueue(event, raw_body)
    end
  end

  # The job carries the received bytes (the processor never reads Payload
  # content; the Payload stays the durable, audited record).
  defp enqueue(event, raw_body) do
    with {:ok, _job} <-
           %{
             "webhook_event_id" => event.id,
             "tenant_id" => event.tenant_id,
             "raw_body" => Base.encode64(raw_body)
           }
           |> WebhookWorker.new()
           |> Oban.insert(),
         do: %{status: :accepted, event: event}
  end

  defp reject(verdict, attrs, whk) do
    with {:ok, event} <-
           create(WebhookEvent, :reject, Map.put(attrs, :signature_verdict, verdict), whk),
         do: %{status: :rejected, event: event}
  end

  # The signature covers the bytes, and the bytes must name the route's
  # event type: a signed event re-posted under another type is not
  # authenticated for that type (rejected; it cannot pre-claim its id).
  defp bind_type(:valid, raw_body, type) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => ^type}} -> :valid
      _ -> :invalid
    end
  end

  defp bind_type(verdict, _raw_body, _type), do: verdict

  defp external_id(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"id" => id}} when is_binary(id) and byte_size(id) in 1..200 -> id
      _ -> "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_body), case: :lower)
    end
  end

  ## Process

  @doc """
  WHK: processes the received WebhookEvent `id` once from `raw_body` — the
  bytes the ingest received and carried in the job (no Payload content is
  read here; the bytes must hash to the event's `raw_body_sha256`, checked
  under the event's row lock). Returns `:ok`, or `{:error, reason}` for a
  transient failure the job should retry. Option `final?: true` (the job's
  last attempt) records a transient failure as `failed` (class `crash`)
  instead; a permanent one (bad bytes, payload, message, token) is always
  `failed` with `validation_error`.

  C3-02 (plan r8 section 6.7; D-174 Q-O5): a matched reply whose hand-off
  defers (`{:deferred, :agent_definition_unavailable}` from
  `SdrAgent.Outreach.ReplyIntake`) commits its reply phase without
  `:mark_processed` and returns `{:error, :agent_definition_unavailable}`
  (retry); on the final attempt the event is `failed`, class `crash`, with
  the fixed reason "#{@handoff_pending}". A later attempt or operator retry
  of that event finds its own stored matched Reply and resumes only the
  hand-off.
  """
  def process(id, tenant_id, raw_body, opts \\ []) do
    whk = Actor.system(:webhook_ingestor, tenant_id)

    case transaction(fn -> process_locked(id, tenant_id, raw_body, whk) end) do
      # C3-02 (plan r8 section 6.7.3 step 5): the reply phase committed, the
      # hand-off is owed and the event stays unprocessed: retry, or on the
      # final attempt fail the event with the fixed, value-free reason.
      {:ok, {:deferred, reason}} ->
        if Keyword.get(opts, :final?, false),
          do: fail(id, tenant_id, :crash, @handoff_pending, whk),
          else: {:error, reason}

      {:ok, _} ->
        :ok

      {:error, {:invalid, reason}} ->
        fail(id, tenant_id, :validation_error, reason, whk)

      {:error, error} ->
        if Keyword.get(opts, :final?, false),
          do: fail(id, tenant_id, :crash, "processing error: #{describe(error)}", whk),
          else: {:error, error}
    end
  end

  # A `received` event, or a `failed` one with an unconsumed operator retry
  # request (S13b B3), is processed; anything else is a no-op — so a resumed
  # or duplicate job never exceeds the operator's bounded requests.
  defp process_locked(id, tenant_id, raw_body, whk) do
    event = lock(WebhookEvent, id, tenant_id)

    if runnable?(event) do
      with {:ok, data} <- decode(event, raw_body),
           :ok <- apply_event(event.event_type, data, event, whk),
           {:ok, _} <- update(event, :mark_processed, %{}, whk),
           do: :processed
    else
      :done
    end
  end

  defp runnable?(%{processing_status: :received}), do: true
  defp runnable?(%{processing_status: :failed} = event), do: pending_retry(event) != nil
  defp runnable?(_event), do: false

  defp fail(id, tenant_id, class, reason, whk) do
    {:ok, _} =
      transaction(fn ->
        case lock(WebhookEvent, id, tenant_id) do
          %{processing_status: :received} = event ->
            update(event, :mark_failed, %{class: class, reason: reason}, whk)

          %{processing_status: :failed} = event ->
            retry_failed(event, class, reason, whk)

          _ ->
            :done
        end
      end)

    :ok
  end

  # B4: the requested retry failed again — consume exactly the pending
  # request; with none pending, nothing (no duplicate Failure).
  defp retry_failed(event, class, reason, whk) do
    case pending_retry(event) do
      nil ->
        :done

      _ordinal ->
        # The action re-derives `ordinal` from the ledger under the lock.
        update(event, :record_retry_failed, %{class: class, reason: reason}, whk)
    end
  end

  defp pending_retry(event), do: WebhookRetryLedger.pending(event)

  defp describe(%{__exception__: true} = error), do: error.__struct__ |> inspect() |> cap()
  defp describe(error), do: error |> inspect(limit: 3, printable_limit: 200) |> cap()

  defp decode(event, raw_body) do
    with true <- is_binary(raw_body) and :crypto.hash(:sha256, raw_body) == event.raw_body_sha256,
         {:ok, %{"data" => data}} when is_map(data) <- Jason.decode(raw_body),
         {:ok, data} <- Zoi.parse(schema(event.event_type), data) do
      {:ok, data}
    else
      false -> {:error, {:invalid, "carried body does not match the event's raw body hash"}}
      _ -> {:error, {:invalid, "payload does not match the #{event.event_type} schema"}}
    end
  end

  defp schema(:reply) do
    Zoi.object(
      %{
        message_id: Zoi.string() |> Zoi.min(1) |> Zoi.max(998),
        in_reply_to: Zoi.string() |> Zoi.max(998) |> Zoi.nullish(),
        from: Zoi.string() |> Zoi.min(3) |> Zoi.max(320),
        to: Zoi.string() |> Zoi.min(3) |> Zoi.max(320),
        subject: Zoi.string() |> Zoi.max(998) |> Zoi.nullish(),
        text: Zoi.string() |> Zoi.min(1) |> Zoi.max(100_000)
      },
      coerce: true
    )
  end

  defp schema(:unsubscribe) do
    Zoi.object(%{contact_id: Zoi.string(), token: Zoi.string() |> Zoi.min(1)}, coerce: true)
  end

  defp schema(_outcome) do
    Zoi.object(
      %{
        provider_message_id: Zoi.string() |> Zoi.min(1),
        reason: Zoi.string() |> Zoi.max(500) |> Zoi.nullish()
      },
      coerce: true
    )
  end

  ## Replies

  defp apply_event(:reply, data, event, whk) do
    from = normalise(data.from)

    with :ok <- valid_email(from),
         :ok <- valid_email(normalise(data.to)),
         {:ok, message_id} <- represented_message_id(data.message_id) do
      # Distinct events can carry one Message-ID: the reply-message key
      # serializes them before the check, so a concurrent duplicate waits
      # and then sees the stored reply.
      pass!(event.tenant_id, [{:"reply-message", message_id}, {:email, from}])

      case stored_reply(message_id, event.tenant_id) do
        nil -> reply(data, message_id, from, event, whk)
        stored -> stored_reply_of(stored, event, whk)
      end
    end
  end

  defp apply_event(:unsubscribe, data, event, whk) do
    with {:ok, contact} <- contact(data.contact_id, event.tenant_id),
         true <-
           Unsubscribe.verify(data.token, event.tenant_id, contact.id) ||
             {:error, {:invalid, "unsubscribe token does not match the contact"}},
         :ok <- hook!(:before_unsubscribe_pass),
         email = normalise(contact.email),
         :ok <- pass!(event.tenant_id, [{:email, email}]),
         :ok <- unchanged_email(contact.id, email, event.tenant_id) do
      lock_suppression(event.tenant_id, email, [])

      with {:ok, decision} <-
             rule_decision(
               whk,
               "outreach.unsubscribe_link",
               WebhookEvent,
               event.id,
               %{"contact_id" => contact.id, "token_verified" => true},
               "unsubscribe"
             ),
           {:ok, _} <-
             suppress(
               %{
                 value: email,
                 reason: :unsubscribe_link,
                 decision_id: decision.id,
                 webhook_event_id: event.id
               },
               whk
             ),
           do: :ok
    end
  end

  defp apply_event(type, data, event, whk) when type in [:delivered, :bounce, :complaint] do
    case delivery_by_message(data.provider_message_id, event.tenant_id) do
      nil ->
        {:error,
         {:invalid, "no delivery has provider message id #{cap(data.provider_message_id)}"}}

      delivery ->
        outcome(type, delivery, data, event, whk)
    end
  end

  defp reply(data, message_id, from, event, whk) do
    match = match(data, from, event.tenant_id)
    hook!(:after_reply_match)

    with :ok <- lock_and_revalidate(match, data, from, event.tenant_id) do
      receive_reply(data, message_id, from, match, event, whk)
    end
  end

  # A matched reply locks its targets (Locks.targets), then recomputes the
  # match under the locks: it must be the same six-field match, with the
  # validated sender as its email; otherwise the attempt rolls back whole
  # (transient), having written nothing of the reply. No key is requested
  # here. An unmatched reply locks nothing, as before.
  defp lock_and_revalidate(nil, _data, _from, _tenant_id), do: :ok

  defp lock_and_revalidate(match, data, from, tenant_id) do
    lock_suppression(tenant_id, match.email, [match.lead_id])

    if match.email == from and match(data, from, tenant_id) == match,
      do: :ok,
      else: {:error, :reply_match_changed}
  end

  defp receive_reply(data, message_id, from, match, event, whk) do
    text = data.text

    attrs =
      Map.merge(
        %{
          webhook_event_id: event.id,
          message_id: message_id,
          in_reply_to: data[:in_reply_to],
          from_email: from,
          to_email: normalise(data.to),
          subject: data[:subject],
          body_text: text
        },
        (match && Map.take(match, [:delivery_operation_id, :contact_id, :lead_id, :enrollment_id])) ||
          %{}
      )

    {outcome, phrases} = UnsubscribeRule.evaluate(data[:subject], text)

    with {:ok, _} <- Audit.put_payload(text, "text/plain; charset=utf-8", actor: whk),
         {:ok, reply} <- create(Reply, :receive, attrs, whk),
         {:ok, decision} <-
           rule_decision(
             whk,
             UnsubscribeRule.id(),
             Reply,
             reply.id,
             %{
               "body_sha256" => Base.encode16(reply.body_sha256, case: :lower),
               "subject" => reply.subject,
               "phrases_matched" => phrases,
               "matched_delivery" => reply.delivery_operation_id
             },
             outcome
           ),
         :ok <- maybe_unsubscribe(outcome, match, reply, decision, event, whk) do
      signal(match, reply, whk)
    end
  end

  defp maybe_unsubscribe("unsubscribe", %{email: email}, reply, decision, event, whk) do
    with {:ok, _} <-
           suppress(
             %{
               value: email,
               reason: :unsubscribe_reply,
               decision_id: decision.id,
               reply_id: reply.id,
               webhook_event_id: event.id
             },
             whk
           ),
         do: :ok
  end

  defp maybe_unsubscribe(_outcome, _match, _reply, _decision, _event, _whk), do: :ok

  # C3-02 (plan r8 section 6.7.3, T2): this event's own matched Reply means
  # its reply phase committed with the hand-off owed (a deferral): resume
  # only the hand-off. A Reply of another event is a duplicate (no-op).
  defp stored_reply_of(
         %Reply{match_status: :matched, webhook_event_id: id} = reply,
         %{id: id} = event,
         whk
       ),
       do: resume(reply, event, whk)

  defp stored_reply_of(_duplicate, _event, _whk), do: :ok

  # The match rebuilt from the stored, append-only Reply (the committed
  # match): lead and enrollment from it, the campaign from its delivery,
  # read unlocked by id and tenant. No revalidation, no Locks.targets, no
  # domain row lock; the hand-off is all that runs.
  defp resume(reply, event, whk) do
    delivery = read(DeliveryOperation, reply.delivery_operation_id, event.tenant_id)

    match = %{
      delivery_operation_id: reply.delivery_operation_id,
      contact_id: reply.contact_id,
      lead_id: reply.lead_id,
      enrollment_id: reply.enrollment_id,
      campaign_id: delivery.campaign_id
    }

    signal(match, reply, whk)
  end

  defp signal(nil, _reply, _whk), do: :ok

  defp signal(match, reply, whk), do: ReplyIntake.impl().received(reply, match, whk)

  # In-Reply-To names a delivery (the capture provider id and the Message-ID
  # share one digest) sent to this sender; otherwise the latest delivery
  # accepted for this sender.
  defp match(data, from, tenant_id) do
    delivery =
      by_in_reply_to(data[:in_reply_to], from, tenant_id) || latest_to(from, tenant_id)

    with %DeliveryOperation{} <- delivery do
      enrollment = read(Sales.CampaignEnrollment, delivery.enrollment_id, tenant_id)

      %{
        delivery_operation_id: delivery.id,
        contact_id: delivery.recipient_contact_id,
        lead_id: enrollment.lead_id,
        enrollment_id: enrollment.id,
        campaign_id: delivery.campaign_id,
        email: normalise(delivery.recipient_email)
      }
    end
  end

  defp by_in_reply_to("<" <> rest, from, tenant_id) do
    with true <- String.ends_with?(rest, @message_host),
         hex = String.replace_suffix(rest, @message_host, ""),
         %DeliveryOperation{} = delivery <- delivery_by_message("capture-" <> hex, tenant_id),
         true <- delivery.state in [:accepted, :delivered, :bounced],
         true <- normalise(delivery.recipient_email) == from do
      delivery
    else
      _ -> nil
    end
  end

  defp by_in_reply_to(_in_reply_to, _from, _tenant_id), do: nil

  defp latest_to(from, tenant_id) do
    DeliveryOperation
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and recipient_email == ^from and state in [:accepted, :delivered]
    )
    |> Ash.Query.sort(accepted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  # The represented Message-ID: the payload value under Reply.message_id's
  # own Ash type and constraints (today trimmed, case kept), so the key, the
  # stored-reply check and the Reply share one value. An empty result (a
  # whitespace-only value) or any constraint error is the fixed schema
  # refusal, before any pass, lookup or write.
  defp represented_message_id(raw) do
    %{type: type, constraints: constraints} = ResourceInfo.attribute(Reply, :message_id)

    with {:ok, cast} <- Ash.Type.cast_input(type, raw, constraints),
         {:ok, value} when is_binary(value) and value != "" <-
           Ash.Type.apply_constraints(type, cast, constraints) do
      {:ok, value}
    else
      _refused -> {:error, {:invalid, @reply_schema_refusal}}
    end
  end

  defp stored_reply(message_id, tenant_id) do
    Reply
    |> Ash.Query.filter(tenant_id == ^tenant_id and message_id == ^message_id)
    |> Ash.read_one!(authorize?: false)
  end

  ## Delivery outcomes

  defp outcome(:delivered, delivery, _data, event, whk) do
    delivery = lock_delivery(delivery, event.tenant_id)

    if delivery.state == :accepted do
      with {:ok, delivery} <- update(delivery, :mark_delivered, %{}, whk),
           {:ok, _} <- receipt(delivery, :delivered, event, whk),
           do: :ok
    else
      :ok
    end
  end

  defp outcome(:bounce, delivery, data, event, whk) do
    email = normalise(delivery.recipient_email)
    pass!(event.tenant_id, [{:email, email}])
    targets = lock_suppression(event.tenant_id, email, [], [delivery.id])
    delivery = Enum.find(targets.locked_deliveries, &(&1.id == delivery.id))

    with :ok <- bounce(delivery, data, event, whk),
         {:ok, _} <-
           suppress(
             %{
               value: email,
               reason: :hard_bounce,
               delivery_operation_id: delivery.id,
               webhook_event_id: event.id
             },
             whk
           ),
         do: :ok
  end

  defp outcome(:complaint, delivery, _data, event, whk) do
    email = normalise(delivery.recipient_email)
    pass!(event.tenant_id, [{:email, email}])
    lock_suppression(event.tenant_id, email, [])

    with {:ok, _} <-
           suppress(
             %{
               value: email,
               reason: :complaint,
               delivery_operation_id: delivery.id,
               webhook_event_id: event.id
             },
             whk
           ),
         do: :ok
  end

  defp bounce(%{state: :accepted} = delivery, data, event, whk) do
    error = %{"reason" => "bounced: #{cap(data[:reason] || "no detail")}"}

    with {:ok, delivery} <- update(delivery, :mark_bounced, %{last_error: error}, whk),
         {:ok, _} <- receipt(delivery, :bounced, event, whk),
         do: :ok
  end

  defp bounce(_delivery, _data, _event, _whk), do: :ok

  # Outcome writers lock enrollment → draft → delivery (S8 order); a bounce
  # locks the suppression's leads → enrollments → drafts → deliveries (with
  # the bounced one) → approvals instead, as it suppresses too.
  defp lock_delivery(delivery, tenant_id) do
    _enrollment = lock(Sales.CampaignEnrollment, delivery.enrollment_id, tenant_id)
    _draft = lock(Draft, delivery.draft_id, tenant_id)
    lock(DeliveryOperation, delivery.id, tenant_id)
  end

  defp receipt(delivery, kind, event, whk) do
    create(
      DeliveryReceipt,
      :record,
      %{
        delivery_operation_id: delivery.id,
        idempotency_key: delivery.idempotency_key,
        kind: kind,
        provider: delivery.provider,
        provider_message_id: delivery.provider_message_id,
        rendered_sha256: delivery.rendered_sha256,
        response_sha256: event.raw_body_sha256,
        webhook_event_id: event.id
      },
      whk
    )
  end

  ## Shared steps

  # The processing transaction's one identity-key pass (its own WebhookEvent
  # row is the only lock before it).
  defp pass!(tenant_id, keys), do: :ok = IdentityKeys.pass(tenant_id, keys)

  # The unsubscribe link's re-read under its email key: the contact must
  # still have the email that was keyed (`:change_email` keys the old email,
  # so the key holds the re-read stable).
  defp unchanged_email(contact_id, email, tenant_id) do
    case read(Sales.Contact, contact_id, tenant_id) do
      %{email: current} -> if normalise(current) == email, do: :ok, else: {:error, :conflict}
      nil -> {:error, :conflict}
    end
  end

  defp lock_suppression(tenant_id, email, lead_ids, delivery_ids \\ []) do
    Locks.targets(tenant_id, %{
      lead_ids: lead_ids,
      contact_ids: Locks.contacts(tenant_id, :email, email),
      delivery_ids: delivery_ids
    })
  end

  defp suppress(attrs, whk),
    do: create(Suppression, :from_webhook, Map.put(attrs, :scope, :email), whk)

  defp rule_decision(whk, rule_id, resource, subject_id, inputs, outcome) do
    Agents.record_decision(
      %{
        kind: :unsubscribe_rule,
        mode: :deterministic,
        rule_id: rule_id,
        rule_version: UnsubscribeRule.version(),
        subject_resource: inspect(resource),
        subject_id: subject_id,
        inputs: inputs,
        outcome: outcome,
        idempotency_key: "#{rule_id}:#{subject_id}"
      },
      actor: whk
    )
  end

  defp contact(id, tenant_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case read(Sales.Contact, id, tenant_id) do
          nil -> {:error, {:invalid, "unknown contact"}}
          contact -> {:ok, contact}
        end

      :error ->
        {:error, {:invalid, "unknown contact"}}
    end
  end

  defp delivery_by_message(pmid, tenant_id) do
    DeliveryOperation
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and provider == :capture and provider_message_id == ^pmid
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp valid_email(email) do
    if NormalizeSuppression.valid?(:email, email),
      do: :ok,
      else: {:error, {:invalid, "not an email address"}}
  end

  defp normalise(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or(ok, _reason), do: ok

  defp cap(value) when is_binary(value), do: binary_part(value, 0, min(byte_size(value), 512))
  defp cap(value), do: value |> to_string() |> cap()

  defp create(resource, action, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(action, attrs, actor: actor)
    |> Ash.create()
  end

  defp update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update()
  end

  # Internal reads and row locks (as Ash's own get_and_lock_for_update);
  # nothing read here is returned to a caller.
  defp read(resource, id, tenant_id) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp lock(resource, id, tenant_id) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  if @test_seams do
    @test_hooks SdrAgent.Outreach.Webhooks.TestHooks

    defp hook!(point), do: @test_hooks.reached(point)
  else
    defp hook!(_point), do: :ok
  end

  defp transaction(fun) do
    Audit.transaction(fn ->
      case fun.() do
        {:error, error} -> Repo.rollback(error)
        value -> value
      end
    end)
  end
end

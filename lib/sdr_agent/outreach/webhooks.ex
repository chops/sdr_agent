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
  plane through `SdrAgent.Outreach.ReplyIntake` in the same transaction), `unsubscribe` (the signed footer link: `Unsubscribe.verify/3` →
  `unsubscribe_link` Suppression), `delivered` and `bounce` (accepted →
  delivered | bounced with a receipt; a bounce always suppresses the
  recipient as `hard_bounce`), `complaint` (`complaint` Suppression).

  Every row lock is taken before the first audit append of the processing
  transaction (`SdrAgent.Outreach.Locks`): event row, then leads →
  enrollments → drafts → deliveries → approvals.
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations.WebhookEvent
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
  """
  def process(id, tenant_id, raw_body, opts \\ []) do
    whk = Actor.system(:webhook_ingestor, tenant_id)

    case transaction(fn -> process_locked(id, tenant_id, raw_body, whk) end) do
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

      ordinal ->
        update(
          event,
          :record_retry_failed,
          %{class: class, reason: reason, ordinal: ordinal},
          whk
        )
    end
  end

  @doc """
  The ordinal of the event's unconsumed operator retry request — its latest
  `webhook.retry_requested` with no later `webhook.retry_failed` — or nil
  (S13b B3). Read under the event's row lock by the processor.
  """
  def pending_retry(event) do
    case retry_ledger(event) do
      [%{event_type: "webhook.retry_requested"} = latest | _] ->
        latest.payload["arguments"]["ordinal"]

      _ ->
        nil
    end
  end

  @doc "The event's retry ledger entries, newest first (S13b)."
  def retry_ledger(event) do
    Audit.AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(event.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^event.tenant_id and subject_id == ^event.id and
        event_type in ["webhook.retry_requested", "webhook.retry_failed"]
    )
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.read!()
  end

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
         :ok <- valid_email(normalise(data.to)) do
      # Distinct events can carry one Message-ID: serialize on it before the
      # check, so a concurrent duplicate waits and then sees the stored reply.
      serialize_message(event.tenant_id, data.message_id)

      if replied?(data.message_id, event.tenant_id),
        do: :ok,
        else: reply(data, from, match(data, from, event.tenant_id), event, whk)
    end
  end

  defp apply_event(:unsubscribe, data, event, whk) do
    with {:ok, contact} <- contact(data.contact_id, event.tenant_id),
         true <-
           Unsubscribe.verify(data.token, event.tenant_id, contact.id) ||
             {:error, {:invalid, "unsubscribe token does not match the contact"}} do
      email = normalise(contact.email)
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

  defp reply(data, from, match, event, whk) do
    text = data.text

    if match, do: lock_suppression(event.tenant_id, match.email, [match.lead_id])

    attrs =
      Map.merge(
        %{
          webhook_event_id: event.id,
          message_id: data.message_id,
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

  defp serialize_message(tenant_id, message_id) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "sdr-reply-message:#{tenant_id}:#{message_id}"
    ])
  end

  defp replied?(message_id, tenant_id) do
    Reply
    |> Ash.Query.filter(tenant_id == ^tenant_id and message_id == ^message_id)
    |> Ash.exists?(authorize?: false)
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

  defp transaction(fun) do
    Audit.transaction(fn ->
      case fun.() do
        {:error, error} -> Repo.rollback(error)
        value -> value
      end
    end)
  end
end

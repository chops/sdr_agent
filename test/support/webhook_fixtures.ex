defmodule SdrAgent.WebhookFixtures do
  @moduledoc """
  Builders for the S9 simulated provider webhook (`capture_sim`): event
  bodies for a delivered message (reply, delivered, bounce, complaint) or an
  unsubscribe link, signed headers built at runtime from the configured
  key, and short readers for WebhookEvents and Replies.
  """

  alias SdrAgent.Clock
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Unsubscribe
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.Outreach.Webhooks.Signature

  @doc "The Message-ID a reply to `delivery` names in In-Reply-To."
  def message_id_of(%{provider_message_id: "capture-" <> hex}), do: "<#{hex}@sdr.example.test>"

  @doc "A reply body (JSON) to `delivery` with `text`; options `:id`, `:from`, `:subject`, `:in_reply_to`."
  def reply_body(delivery, text, opts \\ []) do
    id = Keyword.get(opts, :id, "evt_" <> Ecto.UUID.generate())

    encode(%{
      "id" => id,
      "type" => "reply",
      "occurred_at" => DateTime.to_iso8601(Clock.utc_now()),
      "data" => %{
        "message_id" => "<reply-#{id}@prospect.example.test>",
        "in_reply_to" => Keyword.get(opts, :in_reply_to, message_id_of(delivery)),
        "from" => Keyword.get(opts, :from, to_string(delivery.recipient_email)),
        "to" => "sdr@example.test",
        "subject" => Keyword.get(opts, :subject, "Re: your note"),
        "text" => text
      }
    })
  end

  @doc "A delivered/bounce/complaint body (JSON) for `delivery`."
  def outcome_body(type, delivery, opts \\ []) do
    encode(%{
      "id" => Keyword.get(opts, :id, "evt_" <> Ecto.UUID.generate()),
      "type" => type,
      "occurred_at" => DateTime.to_iso8601(Clock.utc_now()),
      "data" => %{
        "provider_message_id" => delivery.provider_message_id,
        "reason" => Keyword.get(opts, :reason, "mailbox does not exist")
      }
    })
  end

  @doc "An unsubscribe-link body (JSON) for `contact`; option `:token` overrides the real one."
  def unsubscribe_body(contact, opts \\ []) do
    encode(%{
      "id" => Keyword.get(opts, :id, "evt_" <> Ecto.UUID.generate()),
      "type" => "unsubscribe",
      "occurred_at" => DateTime.to_iso8601(Clock.utc_now()),
      "data" => %{
        "contact_id" => contact.id,
        "token" =>
          Keyword.get_lazy(opts, :token, fn ->
            Unsubscribe.token(contact.tenant_id, contact.id)
          end)
      }
    })
  end

  @doc "Signed headers for `body` (options: `:timestamp` unix seconds, `:key`, `:key_id`)."
  def signed_headers(body, opts \\ []) do
    {key_id, key} = Signature.current_key!()
    key = Keyword.get(opts, :key, key)
    key_id = Keyword.get(opts, :key_id, key_id)
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> DateTime.to_unix(Clock.utc_now()) end)

    [
      {"content-type", "application/json"},
      {"x-sdr-key-id", key_id},
      {"x-sdr-timestamp", Integer.to_string(timestamp)},
      {"x-sdr-signature", Signature.sign(key, timestamp, body)}
    ]
  end

  @doc "Ingests a signed `body` of `type` directly (no HTTP)."
  def ingest!(type, body, opts \\ []) do
    Webhooks.ingest(type, body, Map.new(signed_headers(body, opts)))
  end

  @doc """
  After step 1 of `drafted` was accepted: the agent's step-2 draft of the
  same enrollment (pending review), reusing step 1's proposal provenance.
  """
  def followup_draft!(ctx, %{draft: draft, revision: rev}) do
    {:ok, steps} =
      SdrAgent.Sales.list_records(SdrAgent.Sales.SequenceStep, actor: ctx.admin)

    step = Enum.find(steps, &(&1.position == 2))

    {:ok, followup} =
      Outreach.propose_draft(
        %{
          lead_id: draft.lead_id,
          enrollment_id: draft.enrollment_id,
          sequence_step_id: step.id,
          campaign_id: draft.campaign_id,
          recipient_contact_id: draft.recipient_contact_id,
          origin_agent_run_id: draft.origin_agent_run_id,
          subject: "Following up",
          body_text: "Hi again, just following up on my note.",
          decision_id: rev.decision_id,
          model_invocation_id: rev.model_invocation_id,
          citations: []
        },
        actor: ctx.agent
      )

    followup
  end

  @doc "Runs the queued integration (webhook processing) jobs inline."
  def process!,
    do: Oban.drain_queue(queue: :integration, with_safety: false, with_scheduled: true)

  @doc "WebhookEvents (as ADM), oldest first."
  def webhook_events!(ctx) do
    {:ok, events} =
      WebhookEvent
      |> Ash.Query.for_read(:read, %{}, actor: ctx.admin)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.read()

    events
  end

  @doc "Replies (as ADM), oldest first."
  def replies!(ctx) do
    {:ok, replies} = Outreach.list_records(Outreach.Reply, actor: ctx.admin)
    replies
  end

  @doc "Suppressions (as ADM), oldest first."
  def suppressions!(ctx) do
    {:ok, suppressions} = Outreach.list_records(Outreach.Suppression, actor: ctx.admin)
    suppressions
  end

  defp encode(map), do: Jason.encode!(map)
end

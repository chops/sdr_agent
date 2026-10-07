defmodule SdrAgent.Demo.Replies do
  @moduledoc """
  Demo helper (dev/test; `mix sdr.demo.reply`): builds correctly signed
  simulated provider requests (`capture_sim`, checklist 4.3) for a delivered
  message and posts them to *this application's* webhook endpoint — the
  local server, or in-process through `plug:` in tests. Nothing here talks
  to a mail system; there is none (ADR-0001).

  Kinds: `:interested` and `:unsubscribe` (replies to the delivered
  message, threaded by its Message-ID), `:unsubscribe_link` (the footer
  link's signed token), `:delivered`, `:bounce`. The event id is
  deterministic per kind and delivery, so posting the same demo event again
  is acknowledged as a duplicate and changes nothing.
  """

  alias SdrAgent.Clock
  alias SdrAgent.Outreach.Unsubscribe
  alias SdrAgent.Outreach.Webhooks.Signature

  @texts %{
    interested:
      "Thanks for reaching out. This sounds interesting - could we set up a call next week?",
    unsubscribe: "Please unsubscribe me from these emails."
  }
  @local_hosts ["127.0.0.1", "localhost", "::1"]

  @doc "Demo kinds."
  def kinds, do: [:interested, :unsubscribe, :unsubscribe_link, :delivered, :bounce]

  @doc "`%{path, body, headers}` of a signed demo event of `kind` for `delivery`."
  def build(kind, delivery) when kind in [:interested, :unsubscribe] do
    "capture-" <> hex = delivery.provider_message_id

    request("reply", kind, delivery, %{
      "message_id" => "<demo-#{kind}-#{delivery.id}@prospect.example.test>",
      "in_reply_to" => "<#{hex}@sdr.example.test>",
      "from" => to_string(delivery.recipient_email),
      "to" => "sdr@example.test",
      "subject" => "Re: your note",
      "text" => Map.fetch!(@texts, kind)
    })
  end

  def build(:unsubscribe_link, delivery) do
    request("unsubscribe", :unsubscribe_link, delivery, %{
      "contact_id" => delivery.recipient_contact_id,
      "token" => Unsubscribe.token(delivery.tenant_id, delivery.recipient_contact_id)
    })
  end

  def build(kind, delivery) when kind in [:delivered, :bounce] do
    request(Atom.to_string(kind), kind, delivery, %{
      "provider_message_id" => delivery.provider_message_id,
      "reason" => if(kind == :bounce, do: "demo: mailbox does not exist")
    })
  end

  @doc """
  Posts `request` to the webhook endpoint. Options: `:base_url` (default
  `http://127.0.0.1:4120`; only a local host is accepted) or `:plug` (an
  in-process plug, e.g. the Endpoint in tests). Redirects are never
  followed (the signed request cannot leave the local host). Refused with
  `{:error, :demo_disabled}` unless `config :sdr_agent, seeding_allowed?:
  true` (dev and test only). Returns `{:ok, status}`.
  """
  def send_request(%{path: path, body: body, headers: headers}, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "http://127.0.0.1:4120")

    with :ok <- demo_allowed(),
         :ok <- local!(base_url),
         {:ok, response} <-
           Req.post(
             [
               url: base_url <> path,
               body: body,
               headers: headers,
               retry: false,
               redirect: false,
               decode_body: false
             ] ++ Keyword.take(opts, [:plug])
           ) do
      {:ok, response.status}
    end
  end

  @doc "Builds and posts a demo event (`build/2`, `send_request/2`)."
  def post(kind, delivery, opts \\ []), do: kind |> build(delivery) |> send_request(opts)

  defp request(type, kind, delivery, data) do
    body =
      Jason.encode!(%{
        "id" => "demo_#{kind}_#{delivery.id}",
        "type" => type,
        "occurred_at" => DateTime.to_iso8601(Clock.utc_now()),
        "data" => data
      })

    {key_id, key} = Signature.current_key!()
    timestamp = DateTime.to_unix(Clock.utc_now())

    %{
      path: "/webhooks/capture_sim/#{type}",
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"x-sdr-key-id", key_id},
        {"x-sdr-timestamp", Integer.to_string(timestamp)},
        {"x-sdr-signature", Signature.sign(key, timestamp, body)}
      ]
    }
  end

  # Dev/test only (the same switch as the demo seed).
  defp demo_allowed do
    if Application.get_env(:sdr_agent, :seeding_allowed?, false),
      do: :ok,
      else: {:error, :demo_disabled}
  end

  defp local!(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: "http", host: host} when host in @local_hosts -> :ok
      _ -> {:error, :not_a_local_endpoint}
    end
  end
end

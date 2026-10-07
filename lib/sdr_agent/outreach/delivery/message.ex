defmodule SdrAgent.Outreach.Delivery.Message do
  @moduledoc """
  Renders the exact RFC 5322 bytes of an approved revision (S2: "Rendering
  appends the campaign footer and unsubscribe link deterministically
  (footer_template_version), recorded on the DeliveryOperation").

  The same inputs always give the same bytes: headers in a fixed order,
  CRLF line endings, `Date` = the delivery's request instant (the grant),
  `Message-ID` derived from the idempotency key — so every attempt of one
  delivery renders identical bytes (the bound revision, recipient and the
  active campaign's sender and footer cannot change between attempts; the
  gate refuses otherwise). `From` is the campaign sender (default
  "Demo SDR <sdr@example.test>"), `To` the bound recipient email,
  `List-Unsubscribe` (+ one-click) the contact's deterministic link
  (`SdrAgent.Outreach.Unsubscribe`). Header values are folded to one line
  (CR/LF become spaces), so revision text can never add a header. The body
  is the revision text, then the footer of `footer_template_version`.
  """

  alias SdrAgent.Outreach.Unsubscribe

  @footers ["footer/1"]

  @doc "Footer template versions this renderer supports."
  def footer_versions, do: @footers

  @doc """
  The message bytes for `revision` (`subject`, `body_text`) to the
  operation's `recipient_email`, from `campaign` (`sender_name`,
  `sender_email`, `footer_template_version`), with the unsubscribe link of
  `contact_id` in `tenant_id`, dated `at`.
  """
  @spec render(map()) :: binary()
  def render(%{operation: op, revision: revision, campaign: campaign, at: at}) do
    url = Unsubscribe.url(op.tenant_id, op.recipient_contact_id)

    headers = [
      {"From", "#{header(campaign.sender_name)} <#{campaign.sender_email}>"},
      {"To", to_string(op.recipient_email)},
      {"Subject", header(revision.subject)},
      {"Date", Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S +0000")},
      {"Message-ID", "<#{message_id(op.idempotency_key)}@sdr.example.test>"},
      {"MIME-Version", "1.0"},
      {"Content-Type", "text/plain; charset=utf-8"},
      {"Content-Transfer-Encoding", "8bit"},
      {"List-Unsubscribe", "<#{url}>"},
      {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"},
      {"X-SDR-Idempotency-Key", op.idempotency_key}
    ]

    body = revision.body_text <> "\n\n" <> footer(campaign.footer_template_version, campaign, url)

    IO.iodata_to_binary([
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      crlf(body)
    ])
  end

  defp footer("footer/1", campaign, url) do
    "-- \n" <>
      "#{header(campaign.sender_name)} · #{campaign.sender_email}\n" <>
      "You are receiving this message as part of a demo outreach campaign.\n" <>
      "Unsubscribe: #{url}"
  end

  defp header(value), do: value |> to_string() |> String.replace(["\r", "\n"], " ")

  defp crlf(text), do: text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")

  defp message_id(key),
    do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 32)
end

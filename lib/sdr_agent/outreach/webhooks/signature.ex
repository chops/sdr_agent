defmodule SdrAgent.Outreach.Webhooks.Signature do
  @moduledoc """
  Signature of the simulated provider webhook (`capture_sim`; checklist 4.3,
  S2 WebhookEvent): `x-sdr-signature: v1=<hex>` with
  `hex = HMAC-SHA256(key, "<x-sdr-timestamp>.<raw body>")`, the key named by
  `x-sdr-key-id`, the timestamp in unix seconds.

  `verify/3` returns `{verdict, %{key_id:, signed_at:}}` with verdict
  `:missing` (no signature or timestamp header), `:stale` (more than
  300 s from now, either way), `:invalid` (unknown key id, no key
  configured, malformed or wrong signature) or `:valid`. The comparison is
  constant time (`Plug.Crypto.secure_compare/2`) and runs over the exact
  bytes received.

  The key (`config :sdr_agent, :webhook_hmac, key_id:, source:`) is never a
  literal: `:derived` (dev/test) is HMAC-SHA256 of the endpoint
  `secret_key_base` with the label `"sdr-webhook-key/1"`; `{:env, name}`
  (production, injected by the operator's secret tooling) reads it from the
  environment; `{:static, key}` is a key built at runtime (tests). The
  recorded key id is `"webhook_hmac:" <> key_id`, the S2
  IntegrationCredential provider by convention.
  """

  @tolerance 300

  @doc "Allowed clock skew in seconds."
  def tolerance, do: @tolerance

  @doc "`v1=<hex HMAC-SHA256(key, \"<timestamp>.<body>\")>`."
  @spec sign(binary(), integer(), binary()) :: String.t()
  def sign(key, timestamp, body) when is_binary(key) and is_integer(timestamp) do
    "v1=" <>
      (:hmac
       |> :crypto.mac(:sha256, key, [Integer.to_string(timestamp), ".", body])
       |> Base.encode16(case: :lower))
  end

  @doc "Verifies `raw_body` against the signature headers (a map of lowercase names) at `now`."
  @spec verify(map(), binary(), DateTime.t()) ::
          {:valid | :invalid | :missing | :stale,
           %{key_id: String.t() | nil, signed_at: DateTime.t() | nil}}
  def verify(headers, raw_body, now) do
    key_id = header(headers, "x-sdr-key-id")
    signature = header(headers, "x-sdr-signature")
    timestamp = header(headers, "x-sdr-timestamp")
    unix = unix(timestamp)

    verdict =
      cond do
        is_nil(signature) or is_nil(timestamp) -> :missing
        unix == :error -> :invalid
        abs(DateTime.to_unix(now) - unix) > @tolerance -> :stale
        true -> check(key_id, unix, raw_body, signature)
      end

    {verdict,
     %{
       key_id: key_id && "webhook_hmac:" <> key_id,
       signed_at: if(is_integer(unix), do: DateTime.from_unix!(unix))
     }}
  end

  @doc "The configured `{key_id, key}`; raises when no key is available."
  @spec current_key!() :: {String.t(), binary()}
  def current_key! do
    case current_key() do
      {:ok, key} -> key
      :error -> raise ArgumentError, "no webhook HMAC key is configured"
    end
  end

  @doc "The configured `{:ok, {key_id, key}}` or `:error`."
  def current_key do
    config = Application.get_env(:sdr_agent, :webhook_hmac, [])

    with key_id when is_binary(key_id) <- Keyword.get(config, :key_id),
         {:ok, key} <- key(Keyword.get(config, :source)) do
      {:ok, {key_id, key}}
    else
      _ -> :error
    end
  end

  defp key(:derived) do
    case Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])[:secret_key_base] do
      base when is_binary(base) -> {:ok, :crypto.mac(:hmac, :sha256, base, "sdr-webhook-key/1")}
      _ -> :error
    end
  end

  defp key({:env, name}) do
    case System.get_env(name) do
      value when is_binary(value) and byte_size(value) >= 32 -> {:ok, value}
      _ -> :error
    end
  end

  defp key({:static, key}) when is_binary(key) and byte_size(key) >= 32, do: {:ok, key}
  defp key(_source), do: :error

  defp check(key_id, unix, raw_body, signature) do
    with {:ok, {^key_id, key}} <- current_key(),
         "v1=" <> _ <- signature,
         true <- Plug.Crypto.secure_compare(signature, sign(key, unix, raw_body)) do
      :valid
    else
      _ -> :invalid
    end
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp unix(nil), do: :error

  defp unix(value) do
    case Integer.parse(value) do
      {unix, ""} when unix > 0 and unix < 253_402_300_799 -> unix
      _ -> :error
    end
  end
end

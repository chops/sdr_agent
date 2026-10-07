defmodule SdrAgent.Outreach.Unsubscribe do
  @moduledoc """
  The deterministic unsubscribe link of every outbound message (checklist
  1.6: "footer + unsubscribe link → deterministic suppression").

  `token/2` is `base64url(HMAC-SHA256(key, "sdr-unsubscribe/1|<tenant>|<contact>"))`
  with `key = HMAC-SHA256(secret_key_base, "sdr-unsubscribe-key/1")`: the
  same contact always gets the same link, nobody without the endpoint
  secret can forge one, and the token names no address. `url/2` puts it
  under the reserved host `sdr.example.test`. S9 resolves a token back to its
  contact (`verify/3`) when the simulated unsubscribe webhook arrives.
  """

  @host "https://sdr.example.test/unsubscribe/"

  @doc "The unsubscribe token of `contact_id` in `tenant_id`."
  @spec token(String.t(), String.t()) :: String.t()
  def token(tenant_id, contact_id) do
    :hmac
    |> :crypto.mac(:sha256, key(), "sdr-unsubscribe/1|#{tenant_id}|#{contact_id}")
    |> Base.url_encode64(padding: false)
  end

  @doc "The unsubscribe URL of `contact_id` in `tenant_id`."
  @spec url(String.t(), String.t()) :: String.t()
  def url(tenant_id, contact_id), do: @host <> token(tenant_id, contact_id)

  @doc "True when `token` is the unsubscribe token of `contact_id` (constant-time compare)."
  @spec verify(String.t(), String.t(), String.t()) :: boolean()
  def verify(token, tenant_id, contact_id) when is_binary(token),
    do: Plug.Crypto.secure_compare(token, token(tenant_id, contact_id))

  defp key do
    secret =
      :sdr_agent
      |> Application.get_env(SdrAgentWeb.Endpoint, [])
      |> Keyword.get(:secret_key_base) ||
        raise ArgumentError, "the endpoint secret_key_base is required for unsubscribe links"

    :crypto.mac(:hmac, :sha256, secret, "sdr-unsubscribe-key/1")
  end
end

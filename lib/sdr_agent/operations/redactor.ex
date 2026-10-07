defmodule SdrAgent.Operations.Redactor do
  @moduledoc """
  The secret redactor every Failure message (and stored detail) passes
  before insert (S2 row Failure: "Message passes the secret redactor before
  insert"; ADR-0001: never log or persist secret values).

  Replaces secret-shaped substrings with `[REDACTED]`, in this order: PEM
  blocks, `Bearer`/`Basic` credentials, JSON Web Tokens, provider API-key
  shapes (`sk-…`, `ghp_…`, `xoxb-…`), `key=value` / `"key": "value"` pairs
  whose key names a secret (password, secret, token, api key, private key,
  credential, auth…), and long hexadecimal (≥ 32) or base64-like (≥ 40)
  runs. Ordinary diagnostic text is returned unchanged.
  """

  @mask "[REDACTED]"

  @patterns [
    ~r/-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----/s,
    ~r/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i,
    ~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
    ~r/\b(?:sk|pk|rk|ghp|gho|ghs|ghu|xox[abpr])[-_][A-Za-z0-9_-]{16,}/
  ]

  @pair ~r/\b([A-Za-z_-]*(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|auth)[A-Za-z_-]*)("?\s*[:=]\s*"?)([^\s",;}]+)/i
  @runs [~r/\b[0-9a-fA-F]{32,}\b/, ~r/[A-Za-z0-9+\/_-]{40,}={0,2}/]

  @doc "Returns `text` with secret-shaped substrings replaced by `[REDACTED]`."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text =
      Enum.reduce(@patterns, text, fn pattern, acc -> Regex.replace(pattern, acc, @mask) end)

    text = Regex.replace(@pair, text, "\\1\\2" <> @mask)
    Enum.reduce(@runs, text, fn pattern, acc -> Regex.replace(pattern, acc, @mask) end)
  end
end

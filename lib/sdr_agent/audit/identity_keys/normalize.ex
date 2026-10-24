defmodule SdrAgent.Audit.IdentityKeys.Normalize do
  @moduledoc """
  The three domain and email representations of plan r8 section 2.7, each
  applied once per purpose (ADR-0009 C3-02 amendment item 3). Pure; the
  Audit layer never calls Sales.

    * `strip/1`, key and index canonicalization: `lower(btrim(x))` (spaces
      only), then exactly one trailing `.`, then exactly one leading `www.`
      removed. Character for character the SQL `sdr_canonical_domain`
      (`regexp_replace(regexp_replace(lower(btrim(x)), '\\.$', ''),
      '^www\\.', '')`). Total on strings; not idempotent by design
      (`www.www.acme.test` strips to `www.acme.test`).
    * `company/1`, company identity: `c = strip(raw)` accepted only as a
      valid fixed point (a host of at least two labels, at most 253 bytes,
      no leading `www.`, no trailing `.`, `strip(c) == c`) whose input has
      no consecutive dots; otherwise `{:error, :invalid_domain}`.
    * `key_value/2`, the representation guard for key inputs: trimmed and
      lowercased; a `domain` of 1..253 bytes with no `@`, whitespace or
      control character; an `email` with exactly one `@`, non-empty local
      and host parts and no whitespace or control character. No host
      grammar, label-count or reserved-name check, so every currently valid
      suppression and email stays keyable. An unrepresentable input raises
      `IdentityKeys.InvalidKeyValue` carrying the kind only.

  Refusals are fixed and content-free: no input value appears in a return,
  an exception, a log or a span.
  """

  alias SdrAgent.Audit.IdentityKeys.InvalidKeyValue

  # Labels `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`, at least two of them.
  @host ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  @blank ~r/[\s\p{Cc}]/u

  @doc "Key and index canonicalization (see the moduledoc)."
  @spec strip(String.t()) :: String.t()
  def strip(raw) when is_binary(raw) do
    raw
    |> String.trim(" ")
    |> String.downcase()
    |> String.replace_suffix(".", "")
    |> String.replace_prefix("www.", "")
  end

  @doc "Company identity: a valid fixed point, or `{:error, :invalid_domain}`."
  @spec company(term()) :: {:ok, String.t()} | {:error, :invalid_domain}
  def company(raw) when is_binary(raw) do
    with true <- String.valid?(raw) and not String.contains?(raw, ".."),
         c = strip(raw),
         true <- fixed_point?(c) do
      {:ok, c}
    else
      _invalid -> {:error, :invalid_domain}
    end
  end

  def company(_raw), do: {:error, :invalid_domain}

  @doc """
  The representation guard for a key input of `kind` (`:domain` or
  `:email`); returns the trimmed, lowercased value or raises
  `IdentityKeys.InvalidKeyValue`.
  """
  @spec key_value(:domain | :email, term()) :: String.t()
  def key_value(:domain, raw) when is_binary(raw) do
    with true <- String.valid?(raw),
         value = clean(raw),
         true <- byte_size(value) in 1..253 and not String.contains?(value, "@"),
         false <- Regex.match?(@blank, value) do
      value
    else
      _invalid -> invalid(:domain)
    end
  end

  def key_value(:email, raw) when is_binary(raw) do
    with true <- String.valid?(raw),
         value = clean(raw),
         false <- Regex.match?(@blank, value),
         [local, host] when local != "" and host != "" <- String.split(value, "@") do
      value
    else
      _invalid -> invalid(:email)
    end
  end

  def key_value(kind, _raw) when kind in [:domain, :email], do: invalid(kind)
  def key_value(_kind, _raw), do: invalid(:unknown)

  defp fixed_point?(c) do
    byte_size(c) in 1..253 and Regex.match?(@host, c) and not String.starts_with?(c, "www.") and
      strip(c) == c
  end

  defp clean(raw), do: raw |> String.trim() |> String.downcase()

  defp invalid(kind), do: raise(InvalidKeyValue, kind: kind)
end

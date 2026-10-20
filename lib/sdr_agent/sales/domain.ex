defmodule SdrAgent.Sales.Domain do
  @moduledoc """
  The company-identity form of an account domain (packet section 3 Account,
  section 5.4; plan r8 section 2.7; ADR-0009 C3-02 amendment item 3).

  `canonical/1` is `SdrAgent.Audit.IdentityKeys.Normalize.company/1`: the
  stripped value `c` (one trailing `.` and one leading `www.` removed,
  lowercase), accepted only when it is a valid company fixed point (a host of
  at least two labels, at most 253 bytes, no leading `www.`, no trailing `.`,
  no consecutive dots in the input). `Account :create`, `:seed` and
  `:update` store it (`SdrAgent.Sales.Changes.NormalizeDomain`), and the
  admission input hashes it. The SQL function `sdr_canonical_domain(text)`
  (the account index and the `canonical_domain` calculation) is the key form
  `Normalize.strip/1`, of which every accepted value is a fixed point.

  A refusal is the fixed, content-free `{:error, :invalid_domain}`.
  """

  alias SdrAgent.Audit.IdentityKeys.Normalize

  @doc "The company-identity form of `raw`, or `{:error, :invalid_domain}`."
  @spec canonical(term()) :: {:ok, String.t()} | {:error, :invalid_domain}
  def canonical(raw), do: Normalize.company(raw)
end

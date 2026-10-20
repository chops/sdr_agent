defmodule SdrAgent.Sales.SuppressionFacts do
  @moduledoc """
  Sales-owned, read-only, tenant-scoped invariant reads of the do-not-contact
  facts that an identity writer must honour before it changes a company or
  a person identity (plan r8 section 5.4: A.4 for Account `:update`, OQ6 (ii)
  for Contact `:change_email`; D-174 Q-O1 and Q-O2).

  ADR-0009 layering: Sales never calls Outreach, so these reads query the
  `suppressions` table directly, with bound parameters, inside the writer's
  own transaction and under its identity keys, and return a boolean only.
  They are internal invariant reads (as the Research `QualificationRules`
  reads and Ash's own `get_and_lock_for_update`): nothing read here is
  returned to an actor, logged or put in an error.

    * `domain?/2`: a `domain`-scope suppression of the tenant whose value
      equals the company's canonical domain (A.4; the same equality as the
      A.5 cutover fence, `SdrAgent.Sales.CutoverFence`).
    * `address?/2`: the address, or its domain (the host part), is
      suppressed: the `SdrAgent.Outreach.SuppressionMatch.filter/1` rule
      (email equality, or a `domain`-scope value equal to the host),
      mirrored here without calling Outreach. The address is normalised as
      `SuppressionMatch.normalize/1` does (trimmed, lowercase).

  Stored suppression values are lowercase and trimmed (the
  `suppressions_value_normalised` check), so both reads compare text.
  """

  alias SdrAgent.Repo

  @domain_sql """
  SELECT EXISTS (
    SELECT 1 FROM suppressions
     WHERE tenant_id = $1 AND scope = 'domain' AND value::text = $2
  )
  """

  @address_sql """
  SELECT EXISTS (
    SELECT 1 FROM suppressions
     WHERE tenant_id = $1
       AND ((scope = 'email' AND value::text = $2)
            OR (scope = 'domain' AND value::text = split_part($2, '@', 2)))
  )
  """

  @doc "True when the tenant has a `domain` suppression equal to `canonical_domain`."
  @spec domain?(String.t(), String.t()) :: boolean()
  def domain?(tenant_id, canonical_domain)
      when is_binary(tenant_id) and is_binary(canonical_domain),
      do: exists?(@domain_sql, tenant_id, canonical_domain)

  @doc "True when the tenant suppresses `email` or its domain (see the moduledoc)."
  @spec address?(String.t(), String.t()) :: boolean()
  def address?(tenant_id, email) when is_binary(tenant_id) and is_binary(email),
    do: exists?(@address_sql, tenant_id, email |> String.trim() |> String.downcase())

  defp exists?(sql, tenant_id, value) do
    %{rows: [[found?]]} = Repo.query!(sql, [Ecto.UUID.dump!(tenant_id), value])
    found?
  end
end

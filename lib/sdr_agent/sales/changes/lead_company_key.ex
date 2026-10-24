defmodule SdrAgent.Sales.Changes.LeadCompanyKey do
  @moduledoc """
  The company key a Lead write must find held when it runs inside the lead
  admission (C3-02 G4; plan r8 sections 2.6 and 2.7; ADR-0009 C3-02
  amendment item 4), for `SdrAgent.Audit.Changes.IdentityKeyLock` with
  `mode: :none, held_when: SdrAgent.Sales.Checks.LeadAdmissionContext`.

  `keys/1` returns `[{:domain, c}]`, `c` being the authoritative company
  identity of the lead's account: the account's `canonical_domain` read
  from the database (the unique index's expression) by the account id the
  write targets (`:create`: the changeset's `account_id`; `:assign`: the
  stored lead's) and the write's tenant. The admission's pass keyed the
  same bytes (`company/1` of its input, a fixed point of the index
  expression), so `require_held/2` matches; any other account, or a pass
  that did not key this company, fails closed (`LateAcquisition`,
  `MissingPass`). An account that cannot be read gives `[]`: the write
  still requires the admission's pass, and `LeadAccount` then refuses it.
  The runtime check of plan r8 section 2.7: a stored value that is not a
  valid company fixed point (`Domain.canonical(c) == {:ok, c}`; impossible
  after the migration pre-check) is never keyed: it raises the content-free
  `IdentityKeys.InvalidKeyValue` (kind `:domain`), so the write fails
  closed.

  The read is `SdrAgent.Sales.CompanyLock.company/2` (C3-02 G7), an
  internal invariant read (as `LeadAccount`'s): it locks nothing and its
  value is never returned, logged or put in an error.
  Outside the admission (no marker) `IdentityKeyLock` calls nothing here
  for `:assign`. G7 also uses `keys/1` with `mode: :held` on the override
  transitions (`:disqualify_by_override`, `:requalify_by_override`): they
  run only inside a Qualification `:override`, whose pass keyed the same
  company (`SdrAgent.Research.Changes.OverrideCompanyLock`).
  """

  alias SdrAgent.Sales.CompanyLock

  @doc "The held company key of a Lead write (see the moduledoc)."
  @spec keys(Ash.Changeset.t()) :: [{:domain, String.t()}]
  def keys(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    case CompanyLock.company(tenant_id, account_id(changeset)) do
      domain when is_binary(domain) -> [{:domain, domain}]
      nil -> []
    end
  end

  defp account_id(%{action_type: :create} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :account_id)

  defp account_id(changeset), do: Map.get(changeset.data, :account_id)
end

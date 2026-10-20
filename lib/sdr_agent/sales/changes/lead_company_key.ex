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

  The read is an internal invariant read (as `LeadAccount`'s): it locks
  nothing and its value is never returned, logged or put in an error.
  Outside the admission (no marker) `IdentityKeyLock` calls nothing here;
  that path is unchanged until the C3-02 cutover (G5).
  """

  require Ash.Query

  alias SdrAgent.Audit.IdentityKeys.InvalidKeyValue
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Domain

  @doc "The held company key of a Lead write (see the moduledoc)."
  @spec keys(Ash.Changeset.t()) :: [{:domain, String.t()}]
  def keys(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    case canonical_domain(tenant_id, account_id(changeset)) do
      domain when is_binary(domain) -> [{:domain, company!(domain)}]
      _unreadable -> []
    end
  end

  defp company!(domain) do
    case Domain.canonical(domain) do
      {:ok, ^domain} -> domain
      _not_a_fixed_point -> raise InvalidKeyValue, kind: :domain
    end
  end

  defp account_id(%{action_type: :create} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :account_id)

  defp account_id(changeset), do: Map.get(changeset.data, :account_id)

  defp canonical_domain(tenant_id, account_id)
       when is_binary(tenant_id) and is_binary(account_id) do
    Account
    |> Ash.Query.filter(id == ^account_id and tenant_id == ^tenant_id)
    |> Ash.Query.load(:canonical_domain)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %Account{canonical_domain: domain} -> domain
      nil -> nil
    end
  end

  defp canonical_domain(_tenant_id, _account_id), do: nil
end

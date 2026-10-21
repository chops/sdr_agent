defmodule SdrAgent.Sales.CompanyLock do
  @moduledoc """
  Sales-owned, tenant-scoped invariant reads of a lead's company that the
  company-keyed lead writers share (C3-02 G7; plan r8 sections 4.2-4.4,
  5.4 A.3 and 17): Lead `:seed` and `:reopen`
  (`SdrAgent.Sales.Changes.CompanyKey`, `SdrAgent.Sales.Changes.ReopenGuard`)
  and the Research Qualification `:override`
  (`SdrAgent.Research.Changes.OverrideCompanyLock`).

    * `company/2`: the account's `canonical_domain` (the unique index's
      expression, read from the database), unlocked, by account id and
      tenant; `nil` when the account cannot be read. The section 2.7
      runtime check: a stored value that is not a valid company fixed point
      (`Domain.canonical(c) == {:ok, c}`) is never keyed; it raises the
      content-free `IdentityKeys.InvalidKeyValue` (kind `:domain`), so the
      write fails closed.
    * `lock_company/2`: the same account `FOR SHARE` in one statement that
      also selects its `canonical_domain` (the locked re-check's value), or
      `nil` when the account cannot be read.
    * `reopen_refusal/5`: whether re-opening the lead is refused: `:open_lead`
      when another lead of the same tenant and account is open
      (`SdrAgent.Sales.Lead.open_statuses/0`), else `:covered` when the
      lead's contact is covered (A.3: its email or email domain,
      `SuppressionFacts.address?/2`, or the company domain,
      `SuppressionFacts.domain?/2`; a contact that cannot be read is never
      taken as uncovered), else `nil`. Both reads are unlocked: they run
      under the company key, which every writer that can open a lead at
      the account holds, and every suppression locks every lead of the
      contacts it covers, so it serializes with the re-opening writer on
      the lead row (plan section 17.3).

  Every read runs with `authorize?: false` inside the writer's own
  transaction; nothing read here is returned to an actor, logged or put in
  an error. Database and read errors are raised, never turned into a value.
  """

  require Ash.Query

  alias SdrAgent.Audit.IdentityKeys.InvalidKeyValue
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.Domain
  alias SdrAgent.Sales.Lead
  alias SdrAgent.Sales.SuppressionFacts

  @doc "The account's company key value, unlocked, or `nil` (see the moduledoc)."
  @spec company(String.t() | nil, String.t() | nil) :: String.t() | nil
  def company(tenant_id, account_id) when is_binary(tenant_id) and is_binary(account_id) do
    case read_canonical(tenant_id, account_id, nil) do
      domain when is_binary(domain) -> company!(domain)
      nil -> nil
    end
  end

  def company(_tenant_id, _account_id), do: nil

  @doc "The account `FOR SHARE` and its `canonical_domain`, or `nil` (see the moduledoc)."
  @spec lock_company(String.t(), String.t()) :: String.t() | nil
  def lock_company(tenant_id, account_id) when is_binary(tenant_id) and is_binary(account_id),
    do: read_canonical(tenant_id, account_id, "FOR SHARE")

  @doc """
  `:open_lead`, `:covered` or `nil` for re-opening `lead_id` of `account_id`
  and `contact_id` under the key of `company` (see the moduledoc).
  """
  @spec reopen_refusal(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :open_lead | :covered | nil
  def reopen_refusal(tenant_id, lead_id, account_id, contact_id, company)
      when is_binary(tenant_id) and is_binary(lead_id) and is_binary(account_id) and
             is_binary(contact_id) and is_binary(company) do
    cond do
      other_open_lead?(tenant_id, lead_id, account_id) -> :open_lead
      covered?(tenant_id, contact_id, company) -> :covered
      true -> nil
    end
  end

  defp company!(domain) do
    case Domain.canonical(domain) do
      {:ok, ^domain} -> domain
      _not_a_fixed_point -> raise InvalidKeyValue, kind: :domain
    end
  end

  defp read_canonical(tenant_id, account_id, lock) do
    Account
    |> Ash.Query.filter(id == ^account_id and tenant_id == ^tenant_id)
    |> then(&if(lock, do: Ash.Query.lock(&1, lock), else: &1))
    |> Ash.Query.load(:canonical_domain)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %Account{canonical_domain: domain} when is_binary(domain) -> domain
      _unreadable -> nil
    end
  end

  defp other_open_lead?(tenant_id, lead_id, account_id) do
    Lead
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and account_id == ^account_id and id != ^lead_id and
        status in ^Lead.open_statuses()
    )
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> is_struct(Lead)
  end

  defp covered?(tenant_id, contact_id, company) do
    Contact
    |> Ash.Query.filter(id == ^contact_id and tenant_id == ^tenant_id)
    |> Ash.Query.select([:id, :email])
    |> Ash.read_one!(authorize?: false)
    |> case do
      %Contact{email: email} when not is_nil(email) ->
        SuppressionFacts.address?(tenant_id, to_string(email)) or
          SuppressionFacts.domain?(tenant_id, company)

      _unreadable ->
        true
    end
  end
end

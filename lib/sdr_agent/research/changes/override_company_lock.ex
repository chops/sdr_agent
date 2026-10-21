defmodule SdrAgent.Research.Changes.OverrideCompanyLock do
  @moduledoc """
  The human Qualification `:override`'s company key and its pre-INSERT
  order (C3-02 G7; plan r8 sections 4.2, 5.4 A.3 and 17): one prepended
  before_action, so it runs before `Supersedes` and `QualificationRules`
  read and before the INSERT:

    1. the lead, unlocked, by `lead_id` and the changeset's tenant; a lead
       absent from the tenant is `RecordLeadLock.refuse_absent/1`, before
       any key;
    2. the company `c` of the lead's account
       (`SdrAgent.Sales.CompanyLock.company/2`), then
       `SdrAgent.Audit.IdentityKeys.pass(tenant, [{:domain, c}])`; a company
       that cannot be read is the company-changed refusal, before any key;
    3. the account `FOR SHARE` (`CompanyLock.lock_company/2`);
    4. the lead `FOR UPDATE` (`RecordLeadLock.lock_lead/2`);
    5. the re-check on the locked rows: the account's `canonical_domain`
       equals `c` and the lead's `account_id` is unchanged; a mismatch or a
       locked read that returns nothing is the company-changed refusal,
       and no further key is requested;
    6. only when the override re-opens the lead (the superseded row of
       this lead and tenant, read after the lock, has `qualified: false`,
       the new one `qualified: true`, and the locked lead is
       `:disqualified`): another open lead of the account, then A.3 (a
       covered contact), refuse it (`CompanyLock.reopen_refusal/5`). A
       missing or foreign superseded row is not a re-open here; the
       unchanged `Supersedes` rule refuses it next.

  A same-outcome override takes the same key and locks and skips step 6.
  The INSERT, the evidence links and `RecordOutcome`'s lead move follow
  unchanged; the override transitions only require the key held.

  Every refusal of this change is an `InvalidAttribute` on `:lead_id` with
  a fixed message and no value; nothing is written. Identity-key
  exceptions and database errors are raised, never converted.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Audit.IdentityKeys
  alias SdrAgent.Research.Changes.RecordLeadLock
  alias SdrAgent.Research.Qualification
  alias SdrAgent.Sales.CompanyLock
  alias SdrAgent.Sales.Lead

  @changed "the lead's company changed; retry"
  @open_lead "another lead of this account is open"
  @covered "the lead's contact is suppressed"

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.before_action(changeset, &lock/1, prepend?: true)

  defp lock(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    lead_id = Ash.Changeset.get_attribute(changeset, :lead_id)

    if is_binary(tenant_id) and is_binary(lead_id),
      do: lock(changeset, tenant_id, lead_id),
      else: changeset
  end

  defp lock(changeset, tenant_id, lead_id) do
    case read_lead(tenant_id, lead_id) do
      %Lead{account_id: account_id} ->
        case CompanyLock.company(tenant_id, account_id) do
          nil ->
            refuse(changeset, @changed)

          company ->
            :ok = IdentityKeys.pass(tenant_id, [{:domain, company}])
            locked(changeset, tenant_id, lead_id, account_id, company)
        end

      nil ->
        RecordLeadLock.refuse_absent(changeset)
    end
  end

  defp locked(changeset, tenant_id, lead_id, account_id, company) do
    locked_company = CompanyLock.lock_company(tenant_id, account_id)
    lead = RecordLeadLock.lock_lead(tenant_id, lead_id)

    case lead do
      %Lead{account_id: ^account_id} when locked_company == company ->
        reopen_checks(changeset, tenant_id, lead, company)

      _changed ->
        refuse(changeset, @changed)
    end
  end

  defp reopen_checks(changeset, tenant_id, lead, company) do
    if reopens?(changeset, tenant_id, lead) do
      case CompanyLock.reopen_refusal(
             tenant_id,
             lead.id,
             lead.account_id,
             lead.contact_id,
             company
           ) do
        nil -> changeset
        :open_lead -> refuse(changeset, @open_lead)
        :covered -> refuse(changeset, @covered)
      end
    else
      changeset
    end
  end

  defp reopens?(changeset, tenant_id, %Lead{status: :disqualified} = lead) do
    supersedes_id = Ash.Changeset.get_attribute(changeset, :supersedes_id)

    Ash.Changeset.get_attribute(changeset, :qualified) == true and is_binary(supersedes_id) and
      match?(%Qualification{qualified: false}, superseded(tenant_id, lead.id, supersedes_id))
  end

  defp reopens?(_changeset, _tenant_id, _lead), do: false

  # Internal invariant reads (as RecordOutcome's); nothing is returned.
  defp read_lead(tenant_id, lead_id) do
    Lead
    |> Ash.Query.filter(id == ^lead_id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp superseded(tenant_id, lead_id, supersedes_id) do
    Qualification
    |> Ash.Query.filter(id == ^supersedes_id and tenant_id == ^tenant_id and lead_id == ^lead_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp refuse(changeset, message),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :lead_id, message: message)
      )
end

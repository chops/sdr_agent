defmodule SdrAgent.Sales.Changes.ReopenGuard do
  @moduledoc """
  The re-open refusals of Lead `:reopen` (C3-02 G7; plan r8 sections 4.3,
  5.4 A.3 and 17), declared after `get_and_lock_for_update()` and the
  locked `Transition`, so it runs on the lead row re-read `FOR UPDATE`
  (never the caller's struct) and only for a lead that `Transition` found
  `:disqualified`. Under the company key that
  `SdrAgent.Sales.Changes.CompanyKey` passed and re-checked:

    1. the locked lead's `account_id` must be the keyed account's (it is
       immutable under the `leads_identity_immutable` trigger), else
       `CompanyKey`'s fixed company-changed refusal on `:account_id`;
    2. another open lead of the account refuses the re-open:
       `InvalidAttribute` on `:account_id`;
    3. A.3 (D-174 Q-O1): a covered contact refuses it: `InvalidAttribute`
       on `:contact_id`.

  The checks are `SdrAgent.Sales.CompanyLock.reopen_refusal/5`. Every
  refusal has a fixed message and no value; nothing is written and no
  further key is requested.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Sales.Changes.CompanyKey
  alias SdrAgent.Sales.CompanyLock

  @open_lead "another lead of this account is open"
  @covered "the contact is suppressed"

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &guard/1)

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the re-open refusals run on the locked row"}

  defp guard(changeset) do
    %{id: lead_id, tenant_id: tenant_id, account_id: locked_account, contact_id: contact_id} =
      changeset.data

    case CompanyKey.keyed(changeset) do
      {^locked_account, company} ->
        tenant_id
        |> CompanyLock.reopen_refusal(lead_id, locked_account, contact_id, company)
        |> refuse(changeset)

      _not_keyed_for_this_account ->
        CompanyKey.refuse_changed(changeset)
    end
  end

  defp refuse(nil, changeset), do: changeset
  defp refuse(:open_lead, changeset), do: refuse(changeset, :account_id, @open_lead)
  defp refuse(:covered, changeset), do: refuse(changeset, :contact_id, @covered)

  defp refuse(changeset, field, message),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: field, message: message)
      )
end

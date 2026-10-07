defmodule SdrAgent.Sales.Changes.LeadAccount do
  @moduledoc """
  `Lead` create invariants (S2): `account_id` must equal the contact's
  account, and the account must be active ("archived accounts get no new
  leads"). The account row is locked `FOR SHARE` so a concurrent archive
  waits for (or is seen by) this create.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Contact

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      contact_id = Ash.Changeset.get_attribute(changeset, :contact_id)
      account_id = Ash.Changeset.get_attribute(changeset, :account_id)

      with %{account_id: ^account_id} <- read(Contact, contact_id, nil),
           %{status: :active} <- read(Account, account_id, "FOR SHARE") do
        changeset
      else
        %Contact{} ->
          Ash.Changeset.add_error(changeset,
            field: :account_id,
            message: "must be the contact's account"
          )

        %Account{} ->
          Ash.Changeset.add_error(changeset, field: :account_id, message: "account is archived")

        nil ->
          Ash.Changeset.add_error(changeset, field: :contact_id, message: "does not exist")
      end
    end)
  end

  # Internal invariant reads (as Ash's get_and_lock_for_update); nothing is returned.
  defp read(_resource, nil, _lock), do: nil

  defp read(resource, id, lock) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> then(&if(lock, do: Ash.Query.lock(&1, lock), else: &1))
    |> Ash.read_one!(authorize?: false)
  end
end

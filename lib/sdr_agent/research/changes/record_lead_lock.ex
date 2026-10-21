defmodule SdrAgent.Research.Changes.RecordLeadLock do
  @moduledoc """
  Qualification `:record` takes its lead first (C3-02 G7; plan r8 section
  4.6.4 and 17): one prepended before_action, so before `Supersedes` and
  `QualificationRules` read and before the INSERT, locks the lead
  `FOR UPDATE` by `lead_id` and the changeset's tenant (`lock_lead/2`, an
  internal invariant read with `authorize?: false`). No identity key and
  no account lock are taken.

  Every qualification INSERT, root or successor, therefore runs under the
  lead row lock, as the human override's does
  (`SdrAgent.Research.Changes.OverrideCompanyLock`), so no writer holds a
  qualification index entry while it waits for the lead (section 4.6.3).
  The reads after the lock see every qualification committed by an
  earlier holder.

  A lead absent from the tenant (a random id, or a lead of another tenant)
  is the fixed refusal `refuse_absent/1`: `InvalidAttribute` on `:lead_id`
  with no value and the same message in every case; nothing else is read
  or written. A missing tenant (SetTenant refuses) or `lead_id` (the
  required-attribute refusal) is left to those refusals.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Sales.Lead

  @absent "is not a lead of this tenant"

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.before_action(changeset, &lock/1, prepend?: true)

  @doc "The lead `FOR UPDATE` by id and tenant, or `nil` (see the moduledoc)."
  @spec lock_lead(String.t(), String.t()) :: Ash.Resource.record() | nil
  def lock_lead(tenant_id, lead_id) when is_binary(tenant_id) and is_binary(lead_id) do
    Lead
    |> Ash.Query.filter(id == ^lead_id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "The fixed absent-lead refusal on `:lead_id` (see the moduledoc)."
  @spec refuse_absent(Ash.Changeset.t()) :: Ash.Changeset.t()
  def refuse_absent(changeset),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :lead_id, message: @absent)
      )

  defp lock(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    lead_id = Ash.Changeset.get_attribute(changeset, :lead_id)

    cond do
      not (is_binary(tenant_id) and is_binary(lead_id)) -> changeset
      lock_lead(tenant_id, lead_id) -> changeset
      true -> refuse_absent(changeset)
    end
  end
end

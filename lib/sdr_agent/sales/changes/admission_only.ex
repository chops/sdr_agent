defmodule SdrAgent.Sales.Changes.AdmissionOnly do
  @moduledoc """
  Lead `:create` (C3-02 G4; plan r8 section 14 ruling 5): `admission_id`
  is set only from inside the lead admission. A non-nil `admission_id`
  without the `SdrAgent.Sales.Checks.LeadAdmissionContext` marker is
  refused at build time, before any before_action (no key, no lock, no
  write, no event), with a fixed `InvalidAttribute` on `:admission_id` that
  carries no value. With the marker, the database's composite binding
  (`leads_admission_fkey`: tenant, account, contact) and the admission's
  own checks still apply; the marker grants no authorization (the
  `:create` policy is unchanged until the C3-02 cutover, G5, which also
  adds the binding and immutability triggers).
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Sales.Checks.LeadAdmissionContext

  @message "is set only by the lead admission"

  @impl true
  def change(changeset, _opts, _context) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :admission_id)) or
         LeadAdmissionContext.context?(changeset.context),
       do: changeset,
       else:
         Ash.Changeset.add_error(
           changeset,
           InvalidAttribute.exception(field: :admission_id, message: @message)
         )
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:not_atomic, "a create change"}
end

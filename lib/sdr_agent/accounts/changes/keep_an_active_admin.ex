defmodule SdrAgent.Accounts.Changes.KeepAnActiveAdmin do
  @moduledoc """
  S2 User invariant: at least one active admin always. Refuses a role or
  status change that would leave the tenant without an active admin.

  Runs in a `before_action` hook and takes its locks in one fixed order:
  first every active admin of the tenant (`FOR UPDATE`, by id), then the
  target user, whose re-read row replaces the changeset data (so the event's
  `previous` values are exact). Two concurrent demotions of the last two
  admins therefore serialise without deadlocking, and the second one sees a
  single remaining admin. Use it instead of `get_and_lock_for_update`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      admins = lock_active_admins(changeset.resource, changeset.data.tenant_id)
      data = lock(changeset.resource, changeset.data.id)
      changeset = %{changeset | data: data}

      if active_admin?(data) and not active_admin?(after_change(changeset)) and admins <= 1 do
        Ash.Changeset.add_error(changeset,
          field: :role,
          message: "the last active admin cannot be demoted or disabled"
        )
      else
        changeset
      end
    end)
  end

  defp after_change(changeset) do
    %{
      role: Ash.Changeset.get_attribute(changeset, :role),
      status: Ash.Changeset.get_attribute(changeset, :status)
    }
  end

  defp active_admin?(%{role: :admin, status: :active}), do: true
  defp active_admin?(_user), do: false

  defp lock_active_admins(resource, tenant_id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and role == :admin and status == :active)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!()
    |> length()
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end
end

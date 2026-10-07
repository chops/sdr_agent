defmodule SdrAgent.Accounts.Changes.FirstUserOnly do
  @moduledoc """
  `User :bootstrap_admin` precondition (S2: "the bootstrap task for the first
  admin"): the tenant must have no users at all. Fails closed.

  Inside the action's transaction it first locks the tenant row
  `FOR UPDATE` and only then counts the tenant's users, so concurrent
  bootstraps serialise and every one after the first sees a user and is
  refused.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Tenant

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

      cond do
        is_nil(lock_tenant(tenant_id)) ->
          Ash.Changeset.add_error(changeset, field: :tenant_id, message: "tenant does not exist")

        users(changeset.resource, tenant_id) > 0 ->
          Ash.Changeset.add_error(changeset,
            field: :email,
            message:
              "the tenant already has users; the bootstrap creates only the first admin " <>
                "(an admin creates further users with create_user)"
          )

        true ->
          changeset
      end
    end)
  end

  defp lock_tenant(tenant_id) do
    Tenant
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  defp users(resource, tenant_id) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.count!()
  end
end

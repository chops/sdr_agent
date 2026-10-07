defmodule SdrAgent.Audit.Changes.SetTenant do
  @moduledoc """
  Shared create change (ADR-0009 "Tenant"): sets `tenant_id` from the
  actor's tenant. Human operators and system actors both carry `tenant_id`;
  an actor without one cannot create tenant-owned rows.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case tenant_of(context.actor) do
      nil ->
        Ash.Changeset.add_error(changeset, field: :tenant_id, message: "actor has no tenant")

      tenant_id ->
        Ash.Changeset.force_change_attribute(changeset, :tenant_id, tenant_id)
    end
  end

  @doc "The tenant id an actor acts for, if any."
  def tenant_of(%{tenant_id: tenant_id}) when is_binary(tenant_id), do: tenant_id
  def tenant_of(_actor), do: nil
end

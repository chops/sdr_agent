defmodule SdrAgent.Audit.Changes.SetTenant do
  @moduledoc """
  Shared create change (ADR-0009 "Tenant"): sets `tenant_id` from the
  actor's tenant. Human operators and system actors both carry `tenant_id`;
  an actor without one cannot create tenant-owned rows. That refusal is
  raised in a `before_action` hook, i.e. after authorization, so an
  anonymous or tenant-less caller of a guarded action is refused as
  `Forbidden` (and audited) rather than as invalid input.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case tenant_of(context.actor) do
      nil ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          Ash.Changeset.add_error(changeset, field: :tenant_id, message: "actor has no tenant")
        end)

      tenant_id ->
        Ash.Changeset.force_change_attribute(changeset, :tenant_id, tenant_id)
    end
  end

  @doc "The tenant id an actor acts for, if any."
  def tenant_of(%{tenant_id: tenant_id}) when is_binary(tenant_id), do: tenant_id
  def tenant_of(_actor), do: nil
end

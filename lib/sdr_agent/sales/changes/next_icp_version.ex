defmodule SdrAgent.Sales.Changes.NextIcpVersion do
  @moduledoc """
  `IcpDefinition :new_version`: a criteria change after activation is a new
  draft row (S2). Takes the name of the ICP given in argument
  `icp_definition_id`, the next version number of that name in the tenant,
  and — unless supplied — its description and criteria. A concurrent second
  new version of the same name fails on the `(tenant_id, name, version)`
  identity.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    resource = changeset.resource
    id = Ash.Changeset.get_argument(changeset, :icp_definition_id)

    case Ash.read_one!(Ash.Query.filter(resource, id == ^id), authorize?: false) do
      nil ->
        Ash.Changeset.add_error(changeset, field: :icp_definition_id, message: "does not exist")

      source ->
        version =
          resource
          |> Ash.Query.filter(tenant_id == ^source.tenant_id and name == ^source.name)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.version)
          |> Enum.max()

        changeset
        |> Ash.Changeset.force_change_attribute(:name, source.name)
        |> Ash.Changeset.force_change_attribute(:version, version + 1)
        |> default(:description, source.description)
        |> default(:criteria, source.criteria)
    end
  end

  defp default(changeset, attribute, value) do
    if Ash.Changeset.changing_attribute?(changeset, attribute),
      do: changeset,
      else: Ash.Changeset.force_change_attribute(changeset, attribute, value)
  end
end

defmodule SdrAgent.Sales.Changes.CriteriaHash do
  @moduledoc """
  Sets `criteria_sha256` to the canonical (`sdr-canonical-json/1`) SHA-256
  of the ICP's embedded criteria, computed server-side after casting.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :criteria) do
        nil ->
          changeset

        criteria ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :criteria_sha256,
            criteria |> RecordHash.canonical_map() |> Canonical.sha256()
          )
      end
    end)
  end
end

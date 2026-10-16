defmodule SdrAgent.Agents.RunSettings.Validations.OfferingShape do
  @moduledoc """
  Offering profile rules beyond its field constraints (C4 section 3.2):
  item ids are unique within the profile, and the canonical encoding
  (`SdrAgent.Audit.Canonical`) of the whole profile is at most 16 KiB. The
  refusal names the field and rule, never a value.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Audit.Canonical

  @max_bytes 16 * 1024
  @fields [:name, :summary, :audience, :items]

  @impl true
  def validate(changeset, _opts, _context) do
    items = Ash.Changeset.get_attribute(changeset, :items) || []
    ids = Enum.map(items, &Map.get(&1, :id))

    cond do
      length(Enum.uniq(ids)) != length(ids) ->
        {:error, field: :items, message: "item ids must be unique", rule: :duplicate_id}

      too_large?(changeset) ->
        {:error, field: :items, message: "the profile is larger than 16 KiB", rule: :too_large}

      true ->
        :ok
    end
  end

  defp too_large?(changeset) do
    profile = Map.new(@fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

    case Canonical.encode(profile) do
      {:ok, bytes} -> byte_size(bytes) > @max_bytes
      {:error, _reason} -> true
    end
  end
end

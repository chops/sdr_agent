defmodule SdrAgent.Sales.Changes.NormalizeDomain do
  @moduledoc """
  Normalises an account `domain` to the stored form: trimmed and lowercase
  (S2: "lowercase host without scheme"). A scheme, port or path is not
  stripped — such input fails the reserved-domain validation instead.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :domain) do
      {:ok, domain} when not is_nil(domain) ->
        normalized = domain |> to_string() |> String.trim() |> String.downcase()
        Ash.Changeset.force_change_attribute(changeset, :domain, normalized)

      _unchanged ->
        changeset
    end
  end
end

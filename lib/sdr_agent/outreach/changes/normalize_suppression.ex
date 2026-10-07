defmodule SdrAgent.Outreach.Changes.NormalizeSuppression do
  @moduledoc """
  Normalises a Suppression `value` (trimmed, lowercase) and validates its
  shape for the scope: `email` — `local@host`; `domain` — a host name of at
  least two labels. Suppressions are not limited to reserved names: they
  only ever restrict.
  """
  use Ash.Resource.Change

  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @host "(?=.{1,253}$)#{@label}(?:\\.#{@label})+"

  @impl true
  def change(changeset, _opts, _context) do
    scope = Ash.Changeset.get_attribute(changeset, :scope)

    case Ash.Changeset.get_attribute(changeset, :value) do
      nil ->
        changeset

      value ->
        value = value |> to_string() |> String.trim() |> String.downcase()

        if valid?(scope, value),
          do: Ash.Changeset.force_change_attribute(changeset, :value, value),
          else:
            Ash.Changeset.add_error(changeset, field: :value, message: "is not a valid #{scope}")
    end
  end

  @doc "True when `value` (normalised) is a valid value for `scope`."
  def valid?(:email, value) do
    case String.split(value, "@") do
      [local, host] -> Regex.match?(~r/^[^\s@]+$/, local) and host?(host)
      _ -> false
    end
  end

  def valid?(:domain, value), do: host?(value)
  def valid?(_scope, _value), do: false

  defp host?(value), do: Regex.match?(~r/^#{@host}$/, value)
end

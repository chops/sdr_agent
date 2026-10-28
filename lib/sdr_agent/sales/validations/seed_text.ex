defmodule SdrAgent.Sales.Validations.SeedText do
  @moduledoc """
  The content guard of the D-237 seed's four Sales `:seed_prototype`
  actions (text-guard r2; Codex daf5f34e, 8e749d09 T1, 96e75e41). For each
  field in `:fields`, every RAW action input under the field's atom or
  string key (`changeset.params`, before Ash's default `trim?: true` can
  remove an edge character) and the stored value after casting must pass
  the unchanged `SdrAgent.Agents.RunSettings.ContentRules.text/1`. A text
  value is a binary, an atom (as Ash casts it) or an `Ash.CiString`; for
  `:criteria`, every string of the four `SdrAgent.Sales.IcpCriteria` lists
  of a raw map (atom and string keys) or struct, and of the stored struct.
  nil is skipped (`allow_nil?` decides). A raw shape Ash cannot cast as
  text is refused by Ash's own cast at build; any stored value is still
  checked.

  Fields are checked in order and the first failure stops with
  `{field, "is invalid (%{rule})"}`, `rule` its only extra var, never the
  value. Declared first with `before_action?: true`, so it runs after
  authorization and before every other before-action hook (the
  ImportTenant read, the draft-parent lock, the criteria hash). Errors that
  Ash's cast raises or returns at build, before authorization, are not
  this guard's.

  Trust limit: a value set with `Ash.Changeset.change_attribute/3` before
  `for_create/4` is not action input; only its stored value is checked.
  """
  use Ash.Resource.Validation

  alias SdrAgent.Agents.RunSettings.ContentRules
  alias SdrAgent.Sales.IcpCriteria

  @criteria_lists [:industries, :geographies, :personas, :triggers]
  @usage "SeedText requires :fields, a non-empty list of attribute atoms"

  @impl true
  def init(opts) do
    case opts[:fields] do
      [_ | _] = fields ->
        if Enum.all?(fields, &is_atom/1), do: {:ok, opts}, else: {:error, @usage}

      _other ->
        {:error, @usage}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    Enum.reduce_while(opts[:fields], :ok, fn field, :ok ->
      case first_failure(inputs(changeset, field), &rule(field, &1)) do
        :ok ->
          {:cont, :ok}

        {:error, rule} ->
          {:halt, {:error, field: field, message: "is invalid (%{rule})", rule: rule}}
      end
    end)
  end

  # Every raw input under the field's atom or string key, then the stored value.
  defp inputs(changeset, field) do
    key = Atom.to_string(field)
    raw = for {name, value} <- changeset.params, name == field or name == key, do: value
    raw ++ [Ash.Changeset.get_attribute(changeset, field)]
  end

  defp rule(:criteria, criteria) when is_map(criteria),
    do: first_failure(criteria_strings(criteria), &text/1)

  defp rule(_field, value), do: text(value)

  defp criteria_strings(%IcpCriteria{} = criteria),
    do: Enum.flat_map(@criteria_lists, &items(Map.get(criteria, &1)))

  defp criteria_strings(criteria) do
    Enum.flat_map(@criteria_lists, fn list ->
      items(Map.get(criteria, list)) ++ items(Map.get(criteria, Atom.to_string(list)))
    end)
  end

  # A proper list's items; anything else (nil, an improper list, another
  # shape) is Ash's cast to refuse.
  defp items(values) when is_list(values), do: if(proper?(values), do: values, else: [])
  defp items(_other), do: []

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_improper), do: false

  defp text(nil), do: :ok
  defp text(value) when is_binary(value), do: ContentRules.text(value)
  defp text(%Ash.CiString{} = value), do: ContentRules.text(Ash.CiString.value(value))
  defp text(value) when is_atom(value), do: ContentRules.text(Atom.to_string(value))
  defp text(_uncastable), do: :ok

  defp first_failure(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end

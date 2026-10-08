defmodule SdrAgent.AI.JsonSchema do
  @moduledoc """
  The single generator of new JSON schemas for model calls. `render/1` is
  `Zoi.to_json_schema/1` with string keys, then `normalize/1`. It is used by
  `SdrAgent.SDR.Schemas.ref/1` (the `output_schema_sha256` provenance),
  `SdrAgent.AI.ModelProvider` (the stored application request) and
  `SdrAgent.AI.ModelProvider.ClaudeCLI` (the stdin sent to the CLI), so the
  hashed, stored and sent schemas are the same bytes in every VM.

  `Zoi.to_json_schema/1` emits an object's `required` list in an order that
  varies across VM runs. `normalize/1` is schema-aware. It sorts, in byte
  order and without deduplicating or repairing, only the `required` keyword
  of a schema node, when that is a list of strings. It recurses only into
  schema positions:
  - `properties`, `patternProperties`, `$defs`, `definitions` and
    `dependentSchemas` (map values);
  - `additionalProperties`, `unevaluatedProperties`, `items`,
    `unevaluatedItems`, `contains`, `propertyNames`, `not`, `if`, `then`
    and `else` (schema values);
  - `allOf`, `anyOf`, `oneOf` and `prefixItems` (lists, with their order
    kept).

  Literal data (`const`, `default`, `enum`, `examples`) and unknown keywords
  are never modified.

  Historical stored schemas are never normalised.
  `ClaudeCLI.render_prompt/2` (`prompt-builder/1`) is unchanged: it renders
  whatever schema it is given, byte for byte.
  """

  @schema_maps ~w(properties patternProperties $defs definitions dependentSchemas)
  @schema_values ~w(additionalProperties unevaluatedProperties items unevaluatedItems contains
                    propertyNames not if then else)
  @schema_lists ~w(allOf anyOf oneOf prefixItems)

  @doc "The normalised JSON schema (string keys) of a Zoi schema."
  def render(zoi_schema) do
    zoi_schema
    |> Zoi.to_json_schema()
    |> Jason.encode!()
    |> Jason.decode!()
    |> normalize()
  end

  @doc "Sorts schema-node `required` sets; leaves everything else as is."
  def normalize(%{} = node) do
    Map.new(node, fn {key, value} -> {key, keyword(key, value)} end)
  end

  def normalize(other), do: other

  defp keyword("required", list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: Enum.sort(list), else: list
  end

  defp keyword(key, %{} = map) when key in @schema_maps,
    do: Map.new(map, fn {name, schema} -> {name, normalize(schema)} end)

  defp keyword(key, value) when key in @schema_values,
    do: if(is_list(value), do: Enum.map(value, &normalize/1), else: normalize(value))

  defp keyword(key, list) when key in @schema_lists and is_list(list),
    do: Enum.map(list, &normalize/1)

  defp keyword(_key, value), do: value
end

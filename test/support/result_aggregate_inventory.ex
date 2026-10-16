defmodule SdrAgent.Test.ResultAggregateInventory do
  @moduledoc """
  Fail-closed aggregate call-site inventory for the R0 output read gate.
  The single reviewed C1 metadata-only aggregate is recognized by exact
  module/function/arity and closed AST shape, not a file exclusion. Every
  other aggregate surface remains forbidden, including in the same file.
  """

  @surfaces [
    :aggregate,
    :max,
    :min,
    :sum,
    :avg,
    :list,
    :first,
    :aggregate!,
    :max!,
    :min!,
    :sum!,
    :avg!,
    :list!,
    :first!
  ]
  @metadata_call Macro.to_string(
                   quote do
                     Ash.aggregate(
                       [
                         {:total, :count},
                         {:invalid, :sum,
                          expr: expr(if(^invalid, do: 1, else: 0)),
                          expr_type: :integer,
                          default: 0},
                         {:withheld, :sum,
                          expr: expr(if(^withheld, do: 1, else: 0)),
                          expr_type: :integer,
                          default: 0}
                       ],
                       timeout: timeout,
                       authorize?: true,
                       authorize_fields?: true
                     )
                   end
                 )

  @doc "Inspect source AST; malformed source raises rather than disappearing from the inventory."
  def scan(source) do
    result =
      walk(Code.string_to_quoted!(source), {nil, nil}, %{violations: [], approved_count: 0})

    if result.approved_count > 1,
      do: %{result | violations: [:duplicate_approved_site | result.violations]},
      else: result
  end

  defp walk({:defmodule, _, [{:__aliases__, _, name}, [do: body]]}, _, result),
    do: walk(body, {Module.concat(name), nil}, result)

  defp walk({kind, _, [{name, _, args}, [do: body]]}, {module, _}, result)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_atom(name) and is_list(args),
       do: walk(body, {module, {kind, name, length(args)}}, result)

  defp walk({{:., _, [{:__aliases__, _, module}, name]}, meta, _args} = call, context, result)
       when name in @surfaces do
    result =
      if aggregate_surface?(module, name),
        do: record(call, context, meta[:line], result),
        else: result

    walk_children(call, context, result)
  end

  defp walk(node, context, result), do: walk_children(node, context, result)

  defp walk_children(tuple, context, result) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk_children(context, result)

  defp walk_children(list, context, result) when is_list(list),
    do: Enum.reduce(list, result, &walk(&1, context, &2))

  defp walk_children(_, _, result), do: result

  defp aggregate_surface?([:Ash], name), do: name in @surfaces
  defp aggregate_surface?(module, :aggregate), do: List.last(module) == :Query
  defp aggregate_surface?(module, :aggregate!), do: List.last(module) == :Query
  defp aggregate_surface?(_, _), do: false

  defp record(call, {SdrAgent.Outreach.Inbox, {:def, :count_drafts, 1}}, line, result) do
    if Macro.to_string(call) == @metadata_call,
      do: %{result | approved_count: result.approved_count + 1},
      else: %{result | violations: [line | result.violations]}
  end

  defp record(_, _, line, result), do: %{result | violations: [line | result.violations]}
end

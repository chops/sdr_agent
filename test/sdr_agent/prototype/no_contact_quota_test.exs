defmodule SdrAgent.Prototype.NoContactQuotaTest do
  @moduledoc """
  The historical binding policy retains its exact bytes; no runtime code
  may consume its superseded max_contacts field as an admission quota.
  """
  use ExUnit.Case, async: true

  test "max_contacts occurs only as the retained historical policy field" do
    root = Path.expand("../../..", __DIR__)

    references =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        count = file |> File.read!() |> Code.string_to_quoted!() |> count_key()
        if count == 0, do: [], else: [{Path.relative_to(file, root), count}]
      end)

    assert references == [{"lib/sdr_agent/prototype/authority_core.ex", 1}]
  end

  defp count_key(:max_contacts), do: 1
  defp count_key(term) when is_tuple(term), do: term |> Tuple.to_list() |> count_key()
  defp count_key(term) when is_list(term), do: Enum.sum(Enum.map(term, &count_key/1))
  defp count_key(_term), do: 0
end

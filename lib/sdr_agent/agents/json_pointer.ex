defmodule SdrAgent.Agents.JsonPointer do
  @moduledoc "RFC 6901 JSON Pointer resolution over decoded JSON (string-keyed maps, lists)."

  @doc "Resolves `pointer` in `document`: `{:ok, value}` or `:error`."
  @spec resolve(term(), String.t()) :: {:ok, term()} | :error
  def resolve(document, ""), do: {:ok, document}

  def resolve(document, "/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, document}, fn token, {:ok, current} ->
      case step(current, token) do
        {:ok, value} -> {:cont, {:ok, value}}
        :error -> {:halt, :error}
      end
    end)
  end

  def resolve(_document, _pointer), do: :error

  defp step(map, token) when is_map(map) do
    case Enum.find(map, fn {key, _} -> to_string(key) == token end) do
      {_, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp step(list, token) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 and index < length(list) -> {:ok, Enum.at(list, index)}
      _ -> :error
    end
  end

  defp step(_other, _token), do: :error
end

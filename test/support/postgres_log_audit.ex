defmodule SdrAgent.Test.PostgresLogAudit do
  @moduledoc """
  5b (D-178; Codex 5b plan r2 amendment 2): the extension and loaded-module
  audit used by `SdrAgent.PostgresLogSettingsTest`.

  `inventory/1` reads five metadata sources on one connection:

    * installed extensions (`pg_extension`);
    * modules loaded **in this backend** (`pg_get_loaded_modules()`);
    * the three preload settings;
    * `dynamic_library_path`;
    * dotted GUC names (a module's custom settings namespace).

  A source that cannot be read is `:unavailable`.

  `classify/1` classifies each source on its own and reports every one:

    * a pinned benign identity (`SdrAgent.Test.PostgresLogContract`) passes;
    * a known logging facility fails as `:logging`;
    * anything else fails as `:unknown`;
    * an unavailable or missing source fails closed.

  The verdict is `:pass` only when every source passes.

  Required extensions are not required loaded modules: a fresh backend need
  not have loaded any, so an empty loaded-module list passes. A loaded module
  is benign only if its `module_name` is pinned, its version matches, and its
  `file_name` is exactly `<name>.so` or `<name>.dylib`.
  `pg_get_loaded_modules()` reports only a basename, so the audit cannot prove
  a module's directory: a byte-identical copy at a foreign path is
  indistinguishable through this interface. That limit is a reason for the
  limitation, not a benign result.

  Scope: one backend and one database. These are metadata observations and
  defaults, not isolation against a SUPERUSER session or an absolute-path
  `LOAD`.
  """

  alias SdrAgent.Test.PostgresLogContract, as: Contract

  @sources [:extensions, :loaded_modules, :preloads, :dynamic_library_path, :dotted_gucs]
  @logging ~w(auto_explain pgaudit pg_stat_statements log_fdw passwordcheck pg_stat_monitor)
  @preloads ~w(shared_preload_libraries session_preload_libraries local_preload_libraries)

  @doc "Reads the five inventory sources through `repo` (each `:unavailable` on a read error)."
  def inventory(repo) do
    %{
      extensions: rows(repo, "SELECT extname, extversion FROM pg_extension", &List.to_tuple/1),
      loaded_modules:
        rows(
          repo,
          "SELECT module_name, version, file_name FROM pg_get_loaded_modules()",
          &List.to_tuple/1
        ),
      preloads:
        repo
        |> rows("SELECT name, setting FROM pg_settings WHERE name = ANY($1)", &List.to_tuple/1, [
          @preloads
        ])
        |> to_map(),
      dynamic_library_path:
        repo
        |> rows("SELECT current_setting('dynamic_library_path')", &hd/1)
        |> single(),
      dotted_gucs: rows(repo, "SELECT name FROM pg_settings WHERE name LIKE '%.%'", &hd/1)
    }
  end

  @doc "Classifies an inventory; see the moduledoc."
  def classify(inventory) do
    sources =
      Map.new(@sources, fn key -> {key, source(key, Map.get(inventory, key, :unavailable))} end)

    verdict = if Enum.all?(sources, fn {_k, v} -> v == {:pass, []} end), do: :pass, else: :fail
    %{verdict: verdict, sources: sources}
  end

  defp source(_key, :unavailable), do: {:fail, [:unavailable]}

  defp source(:extensions, items) when is_list(items),
    do: result(findings(items, fn {name, version} -> extension(name, version) end))

  defp source(:loaded_modules, items) when is_list(items),
    do: result(findings(items, &module/1))

  defp source(:preloads, %{} = settings) do
    if Enum.all?(@preloads, &Map.has_key?(settings, &1)) do
      result(
        for key <- @preloads,
            entry <- entries(Map.fetch!(settings, key)),
            do: {{key, entry}, if(entry in @logging, do: :logging, else: :unknown)}
      )
    else
      {:fail, [:unavailable]}
    end
  end

  defp source(:dynamic_library_path, "$libdir"), do: {:pass, []}

  defp source(:dynamic_library_path, value) when is_binary(value),
    do: {:fail, [{value, :unknown}]}

  defp source(:dotted_gucs, names) when is_list(names),
    do: result(for name <- names, do: {name, namespace(name)})

  defp source(_key, _malformed), do: {:fail, [:unavailable]}

  defp extension(name, version) do
    cond do
      Map.get(Contract.benign_extensions(), name) == version -> nil
      name in @logging -> :logging
      true -> :unknown
    end
  end

  defp module({name, version, file}) do
    cond do
      Map.get(Contract.benign_modules(), name) == version and
          file in [name <> ".so", name <> ".dylib"] ->
        nil

      name in @logging or stem(file) in @logging ->
        :logging

      true ->
        :unknown
    end
  end

  defp namespace(name),
    do: if(hd(String.split(name, ".")) in @logging, do: :logging, else: :unknown)

  defp stem(file), do: file |> Path.basename() |> Path.rootname()

  defp entries(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # {item, reason} for each item the classifier does not accept (nil = benign).
  defp findings(items, classify) do
    Enum.flat_map(items, fn item ->
      case classify.(item) do
        nil -> []
        reason -> [{item, reason}]
      end
    end)
  end

  defp result([]), do: {:pass, []}
  defp result(findings), do: {:fail, findings}

  defp rows(repo, sql, shape, params \\ []) do
    %{rows: rows} = repo.query!(sql, params)
    Enum.map(rows, shape)
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> :unavailable
  end

  defp to_map(:unavailable), do: :unavailable
  defp to_map(pairs), do: Map.new(pairs)

  defp single([value]) when is_binary(value), do: value
  defp single(_other), do: :unavailable
end

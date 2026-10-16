defmodule SdrAgent.Repo.SafeMetadata do
  @moduledoc """
  The one sanitizer of `[:sdr_agent, :repo, :query]` telemetry events (ADR-0005
  C4 amendment, "metadata-only database logging and spans"; C4 section
  3.6). `fields/2` turns an event into the complete allowlist below; the
  query log (`SdrAgent.Repo.QueryLog`) and the query spans
  (`SdrAgent.Telemetry.RepoSpans`) emit nothing else.

    * `repo` — the repo module name;
    * `source` — a table declared by the app's Ash resources (or Oban's),
      else `"other"`;
    * `command` — `select`, `insert`, `update`, `delete` or `other`;
    * `query_time_us`, `queue_time_us`, `decode_time_us`, `idle_time_us`,
      `total_time_us` — integer microseconds, when measured;
    * `rows` — the result's row count, when it has one;
    * `outcome` — `ok` or `error`;
    * for an error: `error_module` (`Postgrex.Error`,
      `DBConnection.ConnectionError`, `DBConnection.OwnershipError`, else
      `"other"`), `pg_code` (the condition name Postgrex's fixed SQLSTATE
      table gives the error's own SQLSTATE, else `"other"`) and `constraint` (a constraint or index
      name declared by the app's resources, else `"other"`).

  Never: bound parameters, SQL text (in full or as a digest), an exception
  message or `inspect` of any error, PostgreSQL DETAIL, HINT, where or
  column values, the Repo URL, user name, password or connection options.
  """

  @durations [:query_time, :queue_time, :decode_time, :idle_time, :total_time]
  @commands [:select, :insert, :update, :delete]
  @error_modules [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError]
  @extra_tables ["oban_jobs", "oban_peers", "schema_migrations"]
  @names_key {__MODULE__, :names}

  @doc "The allowlisted fields of one query event (see the moduledoc)."
  @spec fields(map(), map()) :: map()
  def fields(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    result = Map.get(metadata, :result)

    %{
      repo: repo(Map.get(metadata, :repo)),
      source: source(Map.get(metadata, :source)),
      command: command(result),
      outcome: outcome(result)
    }
    |> Map.merge(durations(measurements))
    |> Map.merge(rows(result))
    |> Map.merge(error(result))
  end

  @doc "The span status description of an error: fixed identifiers only."
  @spec error_description(map()) :: String.t()
  def error_description(fields) do
    "#{fields[:error_module]} #{fields[:pg_code]} #{fields[:constraint]}"
  end

  defp repo(module) when is_atom(module) and not is_nil(module), do: inspect(module)
  defp repo(_other), do: "other"

  defp source(source) when is_binary(source) do
    if MapSet.member?(names().tables, source), do: source, else: "other"
  end

  defp source(_source), do: "other"

  defp command({:ok, %{command: command}}) when command in @commands, do: Atom.to_string(command)
  defp command(_result), do: "other"

  defp outcome({:ok, _result}), do: "ok"
  defp outcome(_result), do: "error"

  defp durations(measurements) do
    for key <- @durations,
        value = Map.get(measurements, key),
        is_integer(value),
        into: %{} do
      {:"#{key}_us", System.convert_time_unit(value, :native, :microsecond)}
    end
  end

  defp rows({:ok, %{num_rows: rows}}) when is_integer(rows), do: %{rows: rows}
  defp rows(_result), do: %{}

  defp error({:error, %module{} = error}) when module in @error_modules do
    %{error_module: inspect(module), pg_code: pg_code(error), constraint: constraint(error)}
  end

  defp error({:error, _other}),
    do: %{error_module: "other", pg_code: "other", constraint: "other"}

  defp error(_result), do: %{}

  # Only a condition name from Postgrex's fixed SQLSTATE table, and only when
  # it is the name of the error's own SQLSTATE: anything else is "other".
  defp pg_code(%Postgrex.Error{postgres: %{code: code, pg_code: sqlstate}})
       when is_atom(code) and is_binary(sqlstate) do
    case Postgrex.ErrorCode.code_to_name(sqlstate) do
      ^code when not is_nil(code) -> Atom.to_string(code)
      _other -> "other"
    end
  end

  defp pg_code(_error), do: "other"

  defp constraint(%Postgrex.Error{postgres: %{constraint: name}}) when is_binary(name) do
    if MapSet.member?(names().constraints, name), do: name, else: "other"
  end

  defp constraint(_error), do: "other"

  # Tables and constraint names declared by the app's Ash resources, read
  # once from the compiled resources and kept in a persistent term.
  defp names do
    case :persistent_term.get(@names_key, nil) do
      nil ->
        names = declared_names()
        :persistent_term.put(@names_key, names)
        names

      names ->
        names
    end
  end

  defp declared_names do
    resources =
      :sdr_agent
      |> Application.get_env(:ash_domains, [])
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.filter(&(Ash.DataLayer.data_layer(&1) == AshPostgres.DataLayer))

    tables = Enum.map(resources, &AshPostgres.DataLayer.Info.table/1)

    %{
      tables: MapSet.new(tables ++ @extra_tables),
      constraints: MapSet.new(Enum.flat_map(resources, &constraint_names/1))
    }
  end

  defp constraint_names(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)

    checks = Enum.map(AshPostgres.DataLayer.Info.check_constraints(resource), & &1.name)

    identities =
      Enum.map(Ash.Resource.Info.identities(resource), fn identity ->
        AshPostgres.DataLayer.Info.identity_index_names(resource)[identity.name] ||
          "#{table}_#{identity.name}_index"
      end)

    references =
      for relationship <- Ash.Resource.Info.relationships(resource),
          relationship.type == :belongs_to do
        case AshPostgres.DataLayer.Info.reference(resource, relationship.name) do
          %{name: name} when is_binary(name) -> name
          _default -> "#{table}_#{relationship.source_attribute}_fkey"
        end
      end

    indexes =
      Enum.flat_map(AshPostgres.DataLayer.Info.custom_indexes(resource), &List.wrap(&1.name))

    statements =
      Enum.map(AshPostgres.DataLayer.Info.custom_statements(resource), &Atom.to_string(&1.name))

    ["#{table}_pkey" | checks ++ identities ++ references ++ indexes ++ statements]
  end
end

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

  `pg_code` depends on `Postgrex.ErrorCode.code_to_name/1`, an internal
  (`@moduledoc false`) Postgrex function: at the locked Postgrex 0.22.4 it is
  generated from Postgrex's fixed `errcodes.txt` (literal SQLSTATE clauses
  and a catch-all nil; no atom creation). Its stability is not promised by
  Postgrex, so a Postgrex upgrade must re-check it; the upgrade-check tests
  (a known code, an unknown code, a mismatched name and a missing code) pin
  the behaviour, and a failed lookup is always `"other"`, never an
  inspected or free-text fallback.

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

  @ash_classes [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework, Ash.Error.Unknown]
  @raw_prefixes ["Elixir.Postgrex.", "Elixir.DBConnection.", "Elixir.Ash.Error."]
  @scan_budget 50_000

  @doc """
  The sanitized summary of a raw error struct (ADR-0005 C4 amendment, error
  boundaries): for a Postgrex or DBConnection error,
  `"<error_module> <pg_code> <constraint>"` from the allowlisted fields
  above; for an Ash error, its error class (`Ash.Error.Invalid`,
  `Forbidden`, `Framework`, `Unknown`, else `"other"`); anything else
  `"other"`. Fixed identifiers only: never a message, value or `inspect`.
  """
  @spec error_summary(term()) :: String.t()
  def error_summary(%module{} = error) when module in @error_modules,
    do: error_description(error({:error, error}))

  def error_summary(%module{}) when module in @ash_classes, do: inspect(module)
  def error_summary(_error), do: "other"

  @doc """
  The first raw error struct — an exception of the Postgrex, DBConnection
  or Ash error namespaces — found anywhere in `term` (tuples, lists, maps
  and struct fields, depth first), or nil. The walk is bounded: after
  #{@scan_budget} nodes it stops and reports nil.
  """
  @spec find_raw_error(term()) :: struct() | nil
  def find_raw_error(term) do
    case scan(term, @scan_budget) do
      {:found, error} -> error
      _budget -> nil
    end
  end

  defp scan(_term, budget) when budget <= 0, do: 0

  defp scan(%module{} = struct, budget) do
    if raw_error_module?(module),
      do: {:found, struct},
      else: scan_all(Map.values(Map.from_struct(struct)), budget - 1)
  end

  defp scan(map, budget) when is_map(map), do: scan_all(Map.values(map), budget - 1)
  defp scan(list, budget) when is_list(list), do: scan_all(list, budget - 1)
  defp scan(tuple, budget) when is_tuple(tuple), do: scan_all(Tuple.to_list(tuple), budget - 1)
  defp scan(_leaf, budget), do: budget - 1

  defp scan_all([], budget), do: budget
  defp scan_all([head | tail], budget) when is_list(tail), do: scan_next(scan(head, budget), tail)
  # An improper list tail.
  defp scan_all([head | tail], budget), do: scan_next(scan(head, budget), [tail])

  defp scan_next({:found, _} = found, _rest), do: found
  defp scan_next(budget, rest), do: scan_all(rest, budget)

  defp raw_error_module?(module) do
    name = Atom.to_string(module)

    Enum.any?(@raw_prefixes, &String.starts_with?(name, &1)) and
      function_exported?(module, :exception, 1)
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

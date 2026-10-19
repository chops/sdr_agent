defmodule Mix.Tasks.Sdr.Demo.Clients do
  @shortdoc "Counts the other connections to the demo database (dev/test only)"

  @moduledoc """
  Prints `SDR_DEMO_CLIENTS <n>`: the number of server connections to the
  Repo's database other than this task's own, from `pg_stat_activity`. It
  connects to the `postgres` maintenance database, so the demo database need
  not exist (then `n` is 0) and the count never includes this task.

      mix sdr.demo.clients

  `bin/demo reset` refuses to drop the database unless this prints 0 — a
  running app server (any port), an IEx session or a `psql` client all hold
  connections — and then drops without forcing, so Postgres itself refuses
  if a client connects in between. Any failure raises (the script fails
  closed). Refuses outside `MIX_ENV=dev` or `test`.

  Every backend type counts except exactly `"autovacuum worker"` (#201):
  the one type a non-forced `DROP DATABASE` itself asks to exit
  (PostgreSQL 18.6 `CountOtherDBBackends`, `procarray.c:3726-3814`) — nil,
  unknown and background-worker types all block. The label is a display
  string, not the server's internal autovacuum flag (a background worker
  could register the same name), so the non-forced drop stays the final
  interlock.
  """
  use Mix.Task

  @query """
  SELECT backend_type FROM pg_stat_activity
  WHERE datname = $1 AND pid <> pg_backend_pid()
  """

  @doc false
  @impl Mix.Task
  def run(_args) do
    unless Mix.Tasks.Sdr.Demo.Seed.allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.clients runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:postgrex)

    config = SdrAgent.Repo.config()
    database = Keyword.fetch!(config, :database)

    connection =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl])
      |> Keyword.merge(database: "postgres", backoff_type: :stop, pool_size: 1)

    {:ok, conn} = Postgrex.start_link(connection)

    try do
      Mix.shell().info("SDR_DEMO_CLIENTS #{count(conn, database)}")
    after
      GenServer.stop(conn)
    end
  end

  @doc """
  The query behind the count: the `backend_type` of every other backend
  connected to the database given as its one parameter. Run it from a
  connection that is not on that database.
  """
  def query, do: @query

  @doc """
  The number of other backends on `database` that block a reset, read
  through `conn` (a connection to another database). The single entry point
  for this task and the demo test's helper.
  """
  def count(conn, database), do: count_with(fn -> Postgrex.query!(conn, @query, [database]) end)

  @doc """
  `blocking_count/1` of the rows of the `%Postgrex.Result{}` that
  `result_fun` returns; anything else raises `ArgumentError`.
  """
  def count_with(result_fun) when is_function(result_fun, 0) do
    case result_fun.() do
      %Postgrex.Result{rows: rows} -> blocking_count(rows)
      _other -> raise ArgumentError, "#201: the count query did not return a Postgrex result"
    end
  end

  @doc """
  Counts the rows of `query/0`'s result (`[[backend_type], …]`, the type a
  binary or nil) that block a reset: all but exactly `"autovacuum worker"`.
  A row of any other shape raises `ArgumentError` naming its shape, never
  its content.
  """
  def blocking_count(rows) when is_list(rows), do: Enum.count(rows, &blocks?/1)

  defp blocks?(["autovacuum worker"]), do: false
  defp blocks?([type]) when is_binary(type) or is_nil(type), do: true
  defp blocks?(row), do: raise(ArgumentError, "#201: unexpected count row: #{shape(row)}")

  defp shape(row) when is_list(row), do: "a row of #{length(row)} column(s) or a non-text value"
  defp shape(_row), do: "not a row list"
end

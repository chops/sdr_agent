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
  """
  use Mix.Task

  @count """
  SELECT count(*) FROM pg_stat_activity
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
      %Postgrex.Result{rows: [[count]]} = Postgrex.query!(conn, @count, [database])
      Mix.shell().info("SDR_DEMO_CLIENTS #{count}")
    after
      GenServer.stop(conn)
    end
  end
end

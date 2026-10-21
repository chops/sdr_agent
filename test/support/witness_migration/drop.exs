# Projection v4 lineage migration campaign: a normal drop (no FORCE, no
# connection termination) of the database this run claimed, after
# validating the resolved target again. Every other child has exited.
#
# Receipt facts (Codex 9ef62e5 G2), printed as closed `WM-CHILD key=value`
# lines for the harness, never any row content or connection setting:
# the number of backends connected to the target just before the drop, and
# whether the target is absent afterwards. Both are read from the
# maintenance database's catalogs (`pg_stat_activity`, `pg_database`); that
# connection is never to the target itself.
# Usage: mix run --no-start drop.exs DATABASE
Code.require_file("common.exs", __DIR__)

[database] = System.argv()
config = SdrAgent.WitnessMigration.validate_target!(database)

{:ok, _} = Application.ensure_all_started(:postgrex)

maintenance =
  config
  |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl, :parameters])
  |> Keyword.put(:database, Keyword.get(config, :maintenance_database, "postgres"))

{:ok, catalog} = Postgrex.start_link(maintenance)

%{rows: [[backends]]} =
  Postgrex.query!(catalog, "SELECT count(*) FROM pg_stat_activity WHERE datname = $1", [database])

IO.puts("WM-CHILD backends_before_drop=#{backends}")

case Ecto.Adapters.Postgres.storage_down(config) do
  :ok ->
    %{rows: [[present]]} =
      Postgrex.query!(catalog, "SELECT count(*) FROM pg_database WHERE datname = $1", [database])

    IO.puts("WM-CHILD database_absent_after_drop=#{present == 0}")
    GenServer.stop(catalog)
    System.halt(0)

  {:error, reason} ->
    raise "drop failed: #{inspect(reason)}"
end

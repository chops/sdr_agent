# Projection v4 lineage migration campaign: a normal drop (no FORCE, no
# connection termination) of the database this run claimed, after
# validating the resolved target again. Every other child has exited.
#
# The decision is `SdrAgent.WitnessMigration.Harness.drop_flow/1` (Codex
# 7ad3bd0 G2-F1), with the real effects injected here: the target's backend
# count must be zero before the drop (otherwise it refuses, with no drop and
# no termination), the target must be absent afterwards, and both closed
# `WM-CHILD key=value` receipt lines must be written. Both counts are read
# from the maintenance database's catalogs (`pg_stat_activity`,
# `pg_database`); that connection is never to the target itself, and no row
# content or connection setting is ever printed. A refusal prints
# `DROP-REFUSED <label>` and exits with `Harness.drop_refused/0`.
# Usage: mix run --no-start drop.exs DATABASE
Code.require_file("common.exs", __DIR__)

alias SdrAgent.WitnessMigration.Harness

[database] = System.argv()
config = SdrAgent.WitnessMigration.validate_target!(database)

{:ok, _} = Application.ensure_all_started(:postgrex)

maintenance =
  config
  |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl, :parameters])
  |> Keyword.put(:database, Keyword.get(config, :maintenance_database, "postgres"))

{:ok, catalog} = Postgrex.start_link(maintenance)

count = fn sql ->
  %{rows: [[count]]} = Postgrex.query!(catalog, sql, [database])
  count
end

effects = %{
  count_backends: fn -> count.("SELECT count(*) FROM pg_stat_activity WHERE datname = $1") end,
  storage_down: fn -> Ecto.Adapters.Postgres.storage_down(config) end,
  count_present: fn -> count.("SELECT count(*) FROM pg_database WHERE datname = $1") end,
  emit: &IO.puts/1
}

decision = Harness.drop_flow(effects)
GenServer.stop(catalog)

case decision do
  :ok ->
    System.halt(0)

  {:error, reason} ->
    :ok = IO.puts("DROP-REFUSED #{Harness.drop_refusal_label(reason)}")
    System.halt(Harness.drop_refused())
end

# Projection v4 lineage migration campaign: migrate the owned database
# `up` or `down` to VERSION (inclusive) with the project's own migrations,
# after validating the resolved target and before opening any connection.
# The Repo is started here with a plain pool (no sandbox) and stopped
# before exit. Usage: mix run --no-start migrate.exs DATABASE up|down VERSION
Code.require_file("common.exs", __DIR__)

[database, direction, version] = System.argv()
SdrAgent.WitnessMigration.validate_target!(database)

direction =
  case direction do
    "up" -> :up
    "down" -> :down
  end

version = String.to_integer(version)
IO.puts("STARTING after validation")
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

{:ok, _pid} =
  SdrAgent.Repo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2, log: false)

path = Path.join(File.cwd!(), "priv/repo/migrations")
migrated = Ecto.Migrator.run(SdrAgent.Repo, path, direction, to: version, log: false)
IO.puts("migrated #{direction} to #{version}: #{inspect(migrated)}")
:ok = SdrAgent.Repo.stop()

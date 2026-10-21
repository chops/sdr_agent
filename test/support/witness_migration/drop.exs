# Projection v4 lineage migration campaign: a normal drop (no FORCE, no
# connection termination) of the database this run claimed, after
# validating the resolved target again. Every other child has exited.
# Usage: mix run --no-start drop.exs DATABASE
Code.require_file("common.exs", __DIR__)

[database] = System.argv()
config = SdrAgent.WitnessMigration.validate_target!(database)

case Ecto.Adapters.Postgres.storage_down(config) do
  :ok -> System.halt(0)
  {:error, reason} -> raise "drop failed: #{inspect(reason)}"
end

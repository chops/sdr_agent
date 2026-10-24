# C3-02 migration proof: claim the owned database by creating it, only after
# validating the resolved target. Exits 3 when it already exists (refused,
# never migrated or dropped by this run).
# Usage: mix run --no-start claim.exs DATABASE
Code.require_file("common.exs", __DIR__)

[database] = System.argv()
config = SdrAgent.MigrationProof.validate_target!(database)

case Ecto.Adapters.Postgres.storage_up(config) do
  :ok -> System.halt(0)
  {:error, :already_up} -> System.halt(3)
  {:error, reason} -> raise "claim failed: #{inspect(reason)}"
end

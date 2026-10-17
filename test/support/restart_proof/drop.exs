# C9-04 restart proof: drop the database this run claimed, after
# validating the resolved target again. Usage: mix run --no-start drop.exs DATABASE
Code.require_file("common.exs", __DIR__)

[database] = System.argv()
config = SdrAgent.RestartProof.validate_target!(database)

case Ecto.Adapters.Postgres.storage_down(config) do
  :ok -> System.halt(0)
  {:error, reason} -> raise "drop failed: #{inspect(reason)}"
end

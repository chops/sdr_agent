# ADR-0016 adversarial test: build the app schema (no data) on the
# throwaway cluster by running the repo's own migrations. Never run it any
# other way than through throwaway-schema.sh, which validates the cluster
# (guard.sh) first:
#
#   mix run --no-start test/dev_summary_access/migrate_throwaway.exs PORT SYSTEM_IDENTIFIER
#
# Every connection parameter is explicit and replaces the configured repo
# settings entirely; the port must be in 49152-65535 and the server must
# report SYSTEM_IDENTIFIER before any migration runs.

[port_arg, sysid] = System.argv()
port = String.to_integer(port_arg)

if port < 49_152 or port > 65_535 or port in [5520, 4120] or Integer.to_string(port) != port_arg do
  raise "REFUSED: port #{port_arg} is not a throwaway port"
end

repo = SdrAgent.Repo

config = [
  hostname: "127.0.0.1",
  port: port,
  database: "sdr_agent_dev",
  username: "postgres",
  password: "",
  pool_size: 2,
  show_sensitive_data_on_connection_error: false
]

Application.put_env(:sdr_agent, repo, config)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)

effective = repo.config()

unless effective[:port] == port and effective[:hostname] == "127.0.0.1" and
         is_nil(effective[:url]) and is_nil(effective[:socket]) and is_nil(effective[:socket_dir]) do
  raise "REFUSED: the effective repo config is not the throwaway endpoint"
end

{:ok, _} = repo.start_link(config)

%{rows: [[seen]]} =
  repo.query!("SELECT system_identifier::text FROM pg_catalog.pg_control_system()")

if seen != sysid, do: raise("REFUSED: server identity is not the manifest's")

Ecto.Migrator.run(repo, :up, all: true, log: false)
IO.puts("MIGRATED #{length(Ecto.Migrator.migrations(repo))} migrations")

# Projection v4 lineage migration campaign: in a fresh BEAM, prove the
# installed lineage function's behaviour by raw successor inserts against
# committed heads, each rolled back. The first probe ("predecessor")
# commits the heads through the domain APIs and records their ids in
# FIXTURES_JSON. Writes one JSON result.
# The application is started only after the target is validated.
# Usage: mix run --no-start --no-compile probe.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("common.exs", __DIR__)

alias SdrAgent.WitnessMigration

[database, label, fixtures_path, out] = System.argv()
:ok = WitnessMigration.start!(database)
fixtures = WitnessMigration.fixtures!(fixtures_path, label)

File.write!(
  out,
  JSON.encode!(%{
    "database" => database,
    "label" => label,
    "checks" => WitnessMigration.checks(fixtures)
  })
)

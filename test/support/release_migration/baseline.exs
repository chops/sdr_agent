# C2* slice S3 T-S4 release-migration campaign, DB #1 "predecessor" probe
# (S3 plan r2 section 9; `SdrAgent.Agents.ReleaseMigrationTest`, `:external`).
# Run by the OLD (pre-S3) baseline build only, through the harness's
# per-step runner: through the pre-S3 domain APIs it decides one withheld
# and one released ordinary release with their events, verifies the chain,
# and records each release's columns and record hash, every event's row
# fingerprint, the chain heads and the predecessor CHECK definitions in
# FIXTURES_JSON for the later states (`SdrAgent.ReleaseMigration.baseline!/2`).
# Writes one JSON result. It validates its target, and starts the
# application, only through `SdrAgent.WitnessMigration.start!/1`.
# Usage: mix run --no-start --no-compile release_migration/baseline.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)
Code.require_file("common.exs", __DIR__)

alias SdrAgent.ReleaseMigration

[database, label, fixtures_path, out] = System.argv()
:ok = SdrAgent.WitnessMigration.start!(database)

ReleaseMigration.write_result!(
  out,
  database,
  label,
  ReleaseMigration.baseline!(label, fixtures_path)
)

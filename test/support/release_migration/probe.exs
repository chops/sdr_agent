# C2* slice S3 T-S4 release-migration campaign, DB #1 probe for the states
# "up", "down" and "up_again" (S3 plan r2 section 9; Codex 7a9c7eea item 7;
# `SdrAgent.Agents.ReleaseMigrationTest`, `:external`). Run by the NEW build
# after each up and by the OLD build after down: it compares every captured
# event and release (columns and record hash) with the store, verifies the
# chain, accounts for every later event, runs each tamper in a rolled-back
# transaction, and checks the state's schema facts
# (`SdrAgent.ReleaseMigration.probe!/2`). Writes one JSON result. It
# validates its target, and starts the application, only through
# `SdrAgent.WitnessMigration.start!/1`.
# Usage: mix run --no-start --no-compile release_migration/probe.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)
Code.require_file("common.exs", __DIR__)

alias SdrAgent.ReleaseMigration

[database, label, fixtures_path, out] = System.argv()
:ok = SdrAgent.WitnessMigration.start!(database)

ReleaseMigration.write_result!(
  out,
  database,
  label,
  ReleaseMigration.probe!(label, fixtures_path)
)

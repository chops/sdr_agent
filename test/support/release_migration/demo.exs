# C2* slice S3 T-S4 release-migration campaign, DB #2 probe for the states
# "up" and "after_refusal" (S3 plan r2 section 9; Codex 7a9c7eea item 7;
# `SdrAgent.Agents.ReleaseMigrationTest`, `:external`). Run by the NEW build:
# at "up" it commits one demo row through a raw insert that passes every
# CHECK plus a kernel `Audit.append` event with its record hash, verifies the
# chain, detects a rolled-back tamper and records the state; at
# "after_refusal" (after the refused `down`) it proves the full rollback:
# the same applied migrations, columns and CHECK definitions, the row and
# its record hash unchanged, and a valid chain
# (`SdrAgent.ReleaseMigration.demo!/2`). Writes one JSON result. It
# validates its target, and starts the application, only through
# `SdrAgent.WitnessMigration.start!/1`.
# Usage: mix run --no-start --no-compile release_migration/demo.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)
Code.require_file("common.exs", __DIR__)

alias SdrAgent.ReleaseMigration

[database, label, fixtures_path, out] = System.argv()
:ok = SdrAgent.WitnessMigration.start!(database)
ReleaseMigration.write_result!(out, database, label, ReleaseMigration.demo!(label, fixtures_path))

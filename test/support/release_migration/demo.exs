# C2* slice S3 T-S4 release-migration campaign, DB #2 probe for the states
# "up" and "after_refusal" (S3 plan r2 section 9; Codex 7a9c7eea item 7;
# `SdrAgent.Agents.ReleaseMigrationTest`, `:external`). Run by the NEW build:
# at "up" it commits one demo row through a raw insert that passes every
# CHECK plus a kernel `Audit.append` event with its record hash, verifies the
# chain, and detects a rolled-back tamper; at "after_refusal" (after the
# refused `down`) it proves the full rollback. Writes one JSON result.
#
# RED-6 scaffold: it validates its target, then refuses as not implemented
# (status 9) before any startup, connection or effect. GREEN-6 implements it;
# nothing runs it before the campaign packet's own review.
# Usage: mix run --no-start --no-compile release_migration/demo.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)

[database, _label, _fixtures_path, _out] = System.argv()
SdrAgent.WitnessMigration.validate_target!(database)
IO.puts("NOT-IMPLEMENTED release_migration/demo.exs (RED-6 scaffold)")
System.halt(9)

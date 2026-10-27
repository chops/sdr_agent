# C2* slice S3 T-S4 release-migration campaign, DB #1 probe for the states
# "up", "down" and "up_again" (S3 plan r2 section 9; Codex 7a9c7eea item 7;
# `SdrAgent.Agents.ReleaseMigrationTest`, `:external`). Run by the NEW build
# after each up and by the OLD build after down: it verifies the chain, that
# every captured event and record hash is unchanged (legitimate boot appends
# accounted for), and the state's schema facts, with every tamper inside a
# rolled-back transaction. Writes one JSON result.
#
# RED-6 scaffold: it validates its target, then refuses as not implemented
# (status 9) before any startup, connection or effect. GREEN-6 implements it;
# nothing runs it before the campaign packet's own review.
# Usage: mix run --no-start --no-compile release_migration/probe.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)

[database, _label, _fixtures_path, _out] = System.argv()
SdrAgent.WitnessMigration.validate_target!(database)
IO.puts("NOT-IMPLEMENTED release_migration/probe.exs (RED-6 scaffold)")
System.halt(9)

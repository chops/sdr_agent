# C2* slice S3 T-S4 release-migration campaign, DB #1 "predecessor" probe
# (S3 plan r2 section 9; `SdrAgent.Agents.ReleaseMigrationTest`, `:external`).
# Run by the OLD (pre-S3) baseline build only, through the harness's
# per-step runner: through the pre-S3 domain APIs it decides one withheld
# and one released ordinary release with their events, verifies the chain,
# and records each release's columns, record hash, event payload, canonical
# bytes, event hash, the chain head and the predecessor CHECK definitions in
# FIXTURES_JSON for the later states. Writes one JSON result.
#
# RED-6 scaffold: it validates its target, then refuses as not implemented
# (status 9) before any startup, connection or effect. GREEN-6 implements it;
# nothing runs it before the campaign packet's own review.
# Usage: mix run --no-start --no-compile release_migration/baseline.exs DATABASE LABEL FIXTURES_JSON OUT_JSON
Code.require_file("../witness_migration/common.exs", __DIR__)

[database, _label, _fixtures_path, _out] = System.argv()
SdrAgent.WitnessMigration.validate_target!(database)
IO.puts("NOT-IMPLEMENTED release_migration/baseline.exs (RED-6 scaffold)")
System.halt(9)

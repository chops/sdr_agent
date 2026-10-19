-- Throwaway-cluster test data only (ADR-0016 adversarial test, MF2). Run by
-- adversarial.sh after seed.sql, on the guard-verified throwaway cluster.
-- Every value containing "seedsecret" (any case) or "privateclient" must
-- never appear in any function output: each is lowercase, alphanumeric or
-- dotted, so it would have passed the earlier label regexes. The
-- allocations exercise malformed applies_to arrays: an unknown member, a
-- NULL member, a repeated member, 1000 repeated members, two dimensions,
-- an empty array and one 5000-byte member.
\set ON_ERROR_STOP on
SET session_replication_role = replica;

-- Invocations: unknown status and profile on a gen-2 claude_cli row; an
-- unknown provider on a gen-1 row.
SELECT testseed.ins('model_invocations', '{"ledger_generation":"2","provider":"claude_cli","status":"seedsecretstatus","profile_id":"seedsecretprofile","agent_run_id":"00000000-0000-7000-8000-000000000002","tenant_id":"00000000-0000-7000-8000-00000000000f"}');
SELECT testseed.ins('model_invocations', '{"id":"00000000-0000-7000-8000-0000000000c1","ledger_generation":"1","provider":"seedsecretprovider","status":"completed","profile_id":"fake","agent_run_id":"00000000-0000-7000-8000-000000000002","tenant_id":"00000000-0000-7000-8000-00000000000f"}');
-- Bound events whose dotted lowercase types are not in the vocabulary,
-- each carrying a candidate key in payload and canonical bytes.
SELECT testseed.ins('audit_events', '{"event_type":"model.seedsecret","model_invocation_id":"00000000-0000-7000-8000-0000000000a1","tenant_id":"00000000-0000-7000-8000-00000000000f","subject_resource":"SdrAgent.Agents.ModelInvocation","subject_id":"00000000-0000-7000-8000-0000000000a1","payload":"{\"changes\":{\"parsed_output\":1}}","canonical_bytes":"\\x227061727365645f6f7574707574223a31","sequence":"5"}');
SELECT testseed.ins('audit_events', '{"event_type":"model.invocation.seedsecret2","model_invocation_id":"00000000-0000-7000-8000-0000000000c1","tenant_id":"00000000-0000-7000-8000-00000000000f","subject_resource":"SdrAgent.Agents.ModelInvocation","subject_id":"00000000-0000-7000-8000-0000000000c1","payload":"{\"previous\":{\"refusal\":null}}","sequence":"6"}');
-- A release, an export and a run with unknown statuses.
SELECT testseed.ins('model_result_releases', '{"model_invocation_id":"00000000-0000-7000-8000-0000000000a2","disposition":"seedsecretdisposition"}');
SELECT testseed.ins('audit_exports', '{"status":"seedsecretexport","bundle_path":"/seedsecret/path","bundle_sha256":"\\x03"}');
SELECT testseed.ins('agent_runs', '{"status":"seedsecretrun"}');
-- A pending job in an unknown lowercase queue.
SELECT testseed.ins('oban_jobs', '{"queue":"privateclient","state":"available","worker":"W"}');
-- Allocations on the live G-DEMO grant: an unknown key, then malformed
-- applies_to arrays under known keys.
SELECT testseed.ins('model_call_allocations', jsonb_build_object('grant_id', '00000000-0000-7000-8000-0000000000b1', 'tenant_id', '00000000-0000-7000-8000-00000000000f', 'key', k, 'applies_to', a, 'attempts', '1', 'available_from', '2026-10-19 02:20:00'))
FROM (VALUES ('seedsecretkey', '{b1}'),
             ('b2', '{seedsecretbucket}'),
             ('b3', '{b1,NULL}'),
             ('b4', '{b1,b1}'),
             ('b5', '{' || (SELECT string_agg('b1', ',') FROM generate_series(1, 1000)) || '}'),
             ('rehearsal', '{{b1},{b2}}'),
             ('daily_use', '{}'),
             ('proof', '{' || repeat('seedsecretlong', 358) || '}')) AS v(k, a);

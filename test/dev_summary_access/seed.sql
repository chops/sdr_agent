-- Throwaway-cluster test seed only (ADR-0016 adversarial test). Never run
-- against sdr_agent_dev on the dev cluster. Synthetic rows inserted with the
-- replica role (no FK or trigger checks; CHECK constraints still apply).
-- Values containing SEEDSECRET must never appear in any function output.
\set ON_ERROR_STOP on
SET session_replication_role = replica;
-- Throwaway only: drop CHECK constraints so dummy fills are accepted; the
-- functions under test do not depend on them.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
           WHERE contype = 'c' AND connamespace = 'public'::regnamespace LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.t, r.conname);
  END LOOP;
END $$;
CREATE SCHEMA IF NOT EXISTS testseed;
CREATE OR REPLACE FUNCTION testseed.ins(tbl text, overrides jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE cols text := ''; vals text := ''; r record;
BEGIN
  FOR r IN
    SELECT c.column_name, c.udt_name, c.data_type
    FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = tbl
      AND (overrides ? c.column_name OR (c.is_nullable = 'NO' AND c.column_default IS NULL))
    ORDER BY c.ordinal_position
  LOOP
    cols := cols || CASE WHEN cols = '' THEN '' ELSE ', ' END || quote_ident(r.column_name);
    vals := vals || CASE WHEN vals = '' THEN '' ELSE ', ' END ||
      CASE
        WHEN overrides ? r.column_name THEN
          format('%L::%s', overrides ->> r.column_name,
                 CASE WHEN r.data_type = 'ARRAY' THEN substr(r.udt_name, 2) || '[]'
                      WHEN r.data_type = 'USER-DEFINED' THEN 'public.' || r.udt_name
                      ELSE r.udt_name END)
        WHEN r.udt_name = 'uuid' THEN 'gen_random_uuid()'
        WHEN r.udt_name IN ('text', 'varchar', 'citext') THEN '''x'' || substr(md5(random()::text), 1, 12)'
        WHEN r.udt_name IN ('int2', 'int4', 'int8', 'numeric') THEN '(1 + floor(random() * 30000))::int'
        WHEN r.udt_name IN ('timestamp', 'timestamptz') THEN 'now()'
        WHEN r.udt_name IN ('jsonb', 'json') THEN '''{}'''
        WHEN r.udt_name = 'bytea' THEN 'decode(md5(random()::text), ''hex'')'
        WHEN r.udt_name = 'bool' THEN 'false'
        WHEN r.data_type = 'ARRAY' THEN '''{}'''
        ELSE 'NULL'
      END;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s)', tbl, cols, vals);
END $$;

TRUNCATE public.agent_runs, public.oban_jobs, public.model_invocations, public.audit_events,
         public.audit_exports, public.payloads, public.model_call_grants,
         public.model_call_allocations, public.model_result_releases CASCADE;

-- Runs: one queued (a DRAIN 1 hit), one succeeded.
SELECT testseed.ins('agent_runs', '{"id":"00000000-0000-7000-8000-000000000001","status":"queued"}');
SELECT testseed.ins('agent_runs', '{"id":"00000000-0000-7000-8000-000000000002","status":"succeeded"}');
-- Jobs: research available (DRAIN 2), default retryable (context only).
SELECT testseed.ins('oban_jobs', '{"queue":"research","state":"available","worker":"W"}');
SELECT testseed.ins('oban_jobs', '{"queue":"default","state":"retryable","worker":"W"}');
-- Invocations: gen1 completed on the succeeded run; gen2 completed with no
-- release; one reserved on the queued run (DRAIN 3).
SELECT testseed.ins('model_invocations', '{"id":"00000000-0000-7000-8000-0000000000a1","ledger_generation":"1","provider":"claude_cli","status":"completed","profile_id":"claude_cli_opus","agent_run_id":"00000000-0000-7000-8000-000000000002","tenant_id":"00000000-0000-7000-8000-00000000000f"}');
SELECT testseed.ins('model_invocations', '{"id":"00000000-0000-7000-8000-0000000000a2","ledger_generation":"2","provider":"claude_cli","status":"completed","profile_id":"claude_cli_opus","agent_run_id":"00000000-0000-7000-8000-000000000002","tenant_id":"00000000-0000-7000-8000-00000000000f"}');
SELECT testseed.ins('model_invocations', '{"id":"00000000-0000-7000-8000-0000000000a3","ledger_generation":"2","provider":"claude_cli","status":"reserved","profile_id":"claude_cli_opus","agent_run_id":"00000000-0000-7000-8000-000000000001","tenant_id":"00000000-0000-7000-8000-00000000000f"}');
-- Events: one bound gen1 completed with a non-null parsed_output; one
-- unbound; one with an odd event_type (sanitized to 'other').
SELECT testseed.ins('audit_events', '{"event_type":"model.invocation.completed","model_invocation_id":"00000000-0000-7000-8000-0000000000a1","tenant_id":"00000000-0000-7000-8000-00000000000f","subject_resource":"SdrAgent.Agents.ModelInvocation","subject_id":"00000000-0000-7000-8000-0000000000a1","payload":"{\"changes\":{\"parsed_output\":{\"secret\":\"SEEDSECRET-PAYLOAD\"}}}","canonical_bytes":"\\x227061727365645f6f7574707574223a31","sequence":"1"}');
SELECT testseed.ins('audit_events', '{"event_type":"model.launch.refused","tenant_id":"00000000-0000-7000-8000-00000000000f","payload":"{}","sequence":"2"}');
SELECT testseed.ins('audit_events', '{"event_type":"model.X<script>SEEDSECRET-TYPE","tenant_id":"00000000-0000-7000-8000-00000000000f","payload":"{}","sequence":"3"}');
SELECT testseed.ins('audit_events', '{"event_type":"model.Y<b>SEEDSECRET-BOUNDTYPE","model_invocation_id":"00000000-0000-7000-8000-0000000000a1","tenant_id":"00000000-0000-7000-8000-00000000000f","subject_resource":"SdrAgent.Agents.ModelInvocation","subject_id":"00000000-0000-7000-8000-0000000000a1","payload":"{\"changes\":{\"refusal\":null,\"SEEDSECRET-KEY\":1}}","sequence":"4"}');
-- An export and a payload row.
SELECT testseed.ins('audit_exports', '{"status":"written","bundle_path":"/SEEDSECRET-PATH/bundle","bundle_sha256":"\\x01"}');
SELECT testseed.ins('payloads', '{"sha256":"\\x02","content":"\\x534545445345435245542d434f4e54454e54"}');
-- G-DEMO in its reviewed post shape (start 2026-10-19 02:20 UTC), with a
-- secret-bearing name and purpose that must never be read.
SELECT testseed.ins('model_call_grants', '{"id":"00000000-0000-7000-8000-0000000000b1","tenant_id":"00000000-0000-7000-8000-00000000000f","status":"active","profile_ids":"{claude_cli_opus,claude_cli_sonnet}","total_attempts":"200","per_utc_day_attempts":"30","starts_at":"2026-10-19 02:20:00","expires_at":"2026-11-07 06:59:00","name":"SEEDSECRET-NAME","purpose":"SEEDSECRET-PURPOSE"}');
SELECT testseed.ins('model_call_allocations', '{"grant_id":"00000000-0000-7000-8000-0000000000b1","tenant_id":"00000000-0000-7000-8000-00000000000f","key":"b1","applies_to":"{b1}","attempts":"3","available_from":"2026-10-19 02:20:00","available_until":"2026-10-19 03:20:00"}');
SELECT testseed.ins('model_call_allocations', '{"grant_id":"00000000-0000-7000-8000-0000000000b1","tenant_id":"00000000-0000-7000-8000-00000000000f","key":"workshop","applies_to":"{b1,b2,b5}","attempts":"30","available_from":"2026-11-06 07:00:00"}');

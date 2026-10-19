-- D-168 dev-database summary access: install (ADR-0016, proposed).
--
-- Owner-run only, once, as a superuser, connected to sdr_agent_dev:
--   psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
--     -f priv/dev_summary_access/install.sql
-- One transaction: either everything below exists afterwards, or nothing
-- does. The functions are never executable by PUBLIC, not even briefly:
-- they are invisible to other sessions until COMMIT, and PUBLIC EXECUTE is
-- revoked inside the transaction.
--
-- It creates two roles, one schema and two functions, and grants only what
-- those functions need. It changes no privilege of PUBLIC, of the public
-- schema or of any existing role, function or table. The optional,
-- database-wide TEMP hardening is a separate owner decision
-- (optional-revoke-temp.sql).
--
-- No password is set here. If the owner later moves this cluster from
-- `trust` to password authentication, they set the login's password out of
-- band (`\password sdr_summary_login`); it never goes in a file, chat or log.
--
-- After installing, run attest.sql and keep its output: installation and an
-- exact installed-state check are separate prerequisites to any agent use.

\set ON_ERROR_STOP on

SELECT current_database() = 'sdr_agent_dev' AS right_db,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) AS is_super \gset
\if :right_db
\else
  \echo REFUSED: connect to sdr_agent_dev. Nothing was changed.
  \quit
\endif
\if :is_super
\else
  \echo REFUSED: run as a superuser. Nothing was changed.
  \quit
\endif

BEGIN;

-- 1. Roles. CREATE fails if either already exists: an existing role is
-- never silently reused or altered.
CREATE ROLE sdr_summary_definer
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE sdr_summary_login
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT
  CONNECTION LIMIT 2;

-- Session defaults for the login. Defense in depth and operational bounds
-- only: the login can change its own session settings, so none of these is
-- an authorization boundary.
ALTER ROLE sdr_summary_login SET default_transaction_read_only = on;
ALTER ROLE sdr_summary_login SET statement_timeout = '60s';
ALTER ROLE sdr_summary_login SET lock_timeout = '5s';
ALTER ROLE sdr_summary_login SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE sdr_summary_login SET search_path = pg_catalog;

-- 2. Database. PUBLIC already has CONNECT by default; the explicit grant
-- records intent and survives a later REVOKE CONNECT ... FROM PUBLIC.
GRANT CONNECT ON DATABASE sdr_agent_dev TO sdr_summary_login;

-- 3. The interface schema: owned by the installing superuser, so neither
-- new role can create, replace or drop anything in it.
CREATE SCHEMA summary;
REVOKE ALL ON SCHEMA summary FROM PUBLIC;
GRANT USAGE ON SCHEMA summary TO sdr_summary_login, sdr_summary_definer;
ALTER DEFAULT PRIVILEGES IN SCHEMA summary REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE sdr_summary_definer REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 4. The definer's read access: exactly the columns the two functions read,
-- SELECT only. No table-level privilege, no write, no sequence, no other
-- table.
GRANT USAGE ON SCHEMA public TO sdr_summary_definer;
GRANT SELECT (id, tenant_id, ledger_generation, provider, status, profile_id, agent_run_id)
  ON public.model_invocations TO sdr_summary_definer;
GRANT SELECT (model_invocation_id, disposition)
  ON public.model_result_releases TO sdr_summary_definer;
GRANT SELECT (event_type, payload, canonical_bytes, model_invocation_id, tenant_id,
              subject_resource, subject_id)
  ON public.audit_events TO sdr_summary_definer;
GRANT SELECT (status, bundle_sha256, bundle_path) ON public.audit_exports TO sdr_summary_definer;
GRANT SELECT (sha256) ON public.payloads TO sdr_summary_definer;
GRANT SELECT (id, status) ON public.agent_runs TO sdr_summary_definer;
GRANT SELECT (queue, state) ON public.oban_jobs TO sdr_summary_definer;
GRANT SELECT (id, tenant_id, status, starts_at, expires_at, revoked_at, total_attempts,
              per_utc_day_attempts, profile_ids)
  ON public.model_call_grants TO sdr_summary_definer;
GRANT SELECT (grant_id, tenant_id, key, applies_to, attempts, profile_id, available_from,
              available_until, released_at)
  ON public.model_call_allocations TO sdr_summary_definer;

-- 5. summary.g3_inventory_v1(): the accepted G3 metadata inventory
-- (tmp/g3-inventory.sql, sha256 602e9429...) as rows of fixed sections and
-- labels with counts. It never returns a payload value, output, prompt,
-- response, bundle path or scope. Labels that do not match a short
-- lowercase pattern are returned as 'other'. Each section is capped.
-- Read-only by privilege (the definer can only SELECT the columns above)
-- and by volatility (STABLE: one snapshot for the whole call).
CREATE FUNCTION summary.g3_inventory_v1()
RETURNS TABLE (target text, read_at text, fn_version text, section text,
               k1 text, k2 text, k3 text, k4 text, k5 text, n bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
SET search_path = pg_catalog, pg_temp
SET "TimeZone" = 'UTC'
SET lock_timeout = '5s'
AS $fn$
#variable_conflict use_column
DECLARE
  v_t constant text := current_database();
  v_at constant text := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_v constant text := 'summary.g3_inventory_v1';
  -- A section that reaches its row limit makes the result incomplete.
  v_n bigint;
  v_trunc boolean := false;
BEGIN
  RETURN QUERY SELECT v_t, v_at, v_v, 'target'::text, NULL::text, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::bigint;

  -- 1. Every model invocation, by ledger generation, provider and status.
  RETURN QUERY
    SELECT v_t, v_at, v_v, '1 invocations'::text, x.g, x.p, x.s, NULL::text, NULL::text, count(*)
    FROM (SELECT mi.ledger_generation::text AS g,
                 CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END AS p,
                 CASE WHEN mi.status ~ '^[a-z0-9_]{1,32}$' THEN mi.status ELSE 'other' END AS s,
                 mi.ledger_generation AS go
          FROM public.model_invocations mi) x
    GROUP BY x.g, x.p, x.s, x.go ORDER BY x.go, x.p, x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY SELECT v_t, v_at, v_v, '1 invocations total'::text, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::text, count(*)
               FROM public.model_invocations;

  -- 2. Generation-2 ClaudeCLI rows by profile and status.
  RETURN QUERY
    SELECT v_t, v_at, v_v, '2 gen2 claude_cli'::text, x.pr, x.s, NULL::text, NULL::text,
           NULL::text, count(*)
    FROM (SELECT CASE WHEN mi.profile_id ~ '^[a-z0-9_]{1,40}$' THEN mi.profile_id ELSE 'other' END AS pr,
                 CASE WHEN mi.status ~ '^[a-z0-9_]{1,32}$' THEN mi.status ELSE 'other' END AS s
          FROM public.model_invocations mi
          WHERE mi.ledger_generation = 2 AND mi.provider = 'claude_cli') x
    GROUP BY x.pr, x.s ORDER BY x.pr, x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    SELECT v_t, v_at, v_v, '2 gen2 claude_cli completed without release'::text, NULL::text,
           NULL::text, NULL::text, NULL::text, NULL::text, count(*)
    FROM public.model_invocations mi
    WHERE mi.ledger_generation = 2 AND mi.provider = 'claude_cli' AND mi.status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM public.model_result_releases r
                      WHERE r.model_invocation_id = mi.id);

  RETURN QUERY
    SELECT v_t, v_at, v_v, '2 releases'::text, x.d, NULL::text, NULL::text, NULL::text,
           NULL::text, count(*)
    FROM (SELECT CASE WHEN r.disposition ~ '^[a-z0-9_]{1,32}$' THEN r.disposition ELSE 'other' END AS d
          FROM public.model_result_releases r) x
    GROUP BY x.d ORDER BY x.d LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  -- 3. Candidate audit copies of model output, bound to their invocation
  -- by tenant, model_invocation_id and subject; unbound events are kept
  -- and labelled. "Candidate" = the key is present (a JSON null counts);
  -- it does not prove plaintext.
  RETURN QUERY
    WITH ev AS (
      SELECT e.payload,
             CASE
               WHEN e.model_invocation_id IS NULL THEN 'unbound: no invocation id'
               WHEN mi.id IS NULL THEN 'unbound: invocation not found'
               WHEN mi.tenant_id IS DISTINCT FROM e.tenant_id
                 OR e.subject_resource IS DISTINCT FROM 'SdrAgent.Agents.ModelInvocation'
                 OR e.subject_id IS DISTINCT FROM mi.id::text THEN 'inconsistent binding'
               ELSE 'gen' || mi.ledger_generation || ' '
                    || CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END
             END AS binding
      FROM public.audit_events e
      LEFT JOIN public.model_invocations mi ON mi.id = e.model_invocation_id
      WHERE e.event_type LIKE 'model.%'
         OR e.subject_resource = 'SdrAgent.Agents.ModelInvocation'
         OR e.model_invocation_id IS NOT NULL
    )
    -- Columns as in the psql version: binding, events, with_redacted_marker,
    -- with_output_commitment (n is null for this section).
    SELECT v_t, v_at, v_v, '3 model-related events'::text, ev.binding,
           count(*)::text,
           count(*) FILTER (WHERE ev.payload ? 'redacted')::text,
           count(*) FILTER (WHERE ev.payload ? 'output_commitment')::text,
           NULL::text, NULL::bigint
    FROM ev GROUP BY ev.binding ORDER BY ev.binding LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    WITH ev AS (
      SELECT e.payload,
             CASE WHEN e.event_type ~ '^[a-z0-9_.]{1,64}$' THEN e.event_type ELSE 'other' END AS event_type,
             CASE
               WHEN e.model_invocation_id IS NULL THEN 'unbound: no invocation id'
               WHEN mi.id IS NULL THEN 'unbound: invocation not found'
               WHEN mi.tenant_id IS DISTINCT FROM e.tenant_id
                 OR e.subject_resource IS DISTINCT FROM 'SdrAgent.Agents.ModelInvocation'
                 OR e.subject_id IS DISTINCT FROM mi.id::text THEN 'inconsistent binding'
               ELSE 'gen' || mi.ledger_generation || ' '
                    || CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END
             END AS binding
      FROM public.audit_events e
      LEFT JOIN public.model_invocations mi ON mi.id = e.model_invocation_id
      WHERE e.event_type LIKE 'model.%'
         OR e.subject_resource = 'SdrAgent.Agents.ModelInvocation'
         OR e.model_invocation_id IS NOT NULL
    )
    SELECT v_t, v_at, v_v, '3 candidate payload keys'::text, ev.binding, ev.event_type,
           loc.location, k.field,
           CASE WHEN jsonb_typeof(ev.payload -> loc.location -> k.field) = 'null'
                THEN 'null' ELSE 'non-null' END,
           count(*)
    FROM ev
    CROSS JOIN unnest(ARRAY['changes', 'previous', 'arguments']) AS loc(location)
    CROSS JOIN unnest(ARRAY['parsed_output', 'validation_errors', 'refusal']) AS k(field)
    WHERE jsonb_typeof(ev.payload -> loc.location) = 'object'
      AND (ev.payload -> loc.location) ? k.field
    GROUP BY 5, 6, 7, 8, 9 ORDER BY 5, 6, 7, 8, 9 LIMIT 300;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 300 THEN v_trunc := true; END IF;

  RETURN QUERY
    WITH ev AS (
      SELECT e.canonical_bytes,
             CASE WHEN e.event_type ~ '^[a-z0-9_.]{1,64}$' THEN e.event_type ELSE 'other' END AS event_type,
             CASE
               WHEN e.model_invocation_id IS NULL THEN 'unbound: no invocation id'
               WHEN mi.id IS NULL THEN 'unbound: invocation not found'
               WHEN mi.tenant_id IS DISTINCT FROM e.tenant_id
                 OR e.subject_resource IS DISTINCT FROM 'SdrAgent.Agents.ModelInvocation'
                 OR e.subject_id IS DISTINCT FROM mi.id::text THEN 'inconsistent binding'
               ELSE 'gen' || mi.ledger_generation || ' '
                    || CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END
             END AS binding
      FROM public.audit_events e
      LEFT JOIN public.model_invocations mi ON mi.id = e.model_invocation_id
      WHERE e.event_type LIKE 'model.%'
         OR e.subject_resource = 'SdrAgent.Agents.ModelInvocation'
         OR e.model_invocation_id IS NOT NULL
    )
    SELECT v_t, v_at, v_v, '3 candidate canonical keys'::text, ev.binding, ev.event_type, k.field,
           NULL::text, NULL::text, count(*)
    FROM ev
    CROSS JOIN unnest(ARRAY['parsed_output', 'validation_errors', 'refusal']) AS k(field)
    WHERE position(convert_to('"' || k.field || '":', 'UTF8') IN ev.canonical_bytes) > 0
    GROUP BY 5, 6, 7 ORDER BY 5, 6, 7 LIMIT 300;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 300 THEN v_trunc := true; END IF;

  -- 4. Audit exports: metadata only. A zero does not prove no external
  -- copy exists (the owner answers that separately).
  RETURN QUERY
    -- Columns as in the psql version: status, rows, with_bundle_hash,
    -- with_bundle_path_recorded (n is null for this section).
    SELECT v_t, v_at, v_v, '4 audit exports'::text, x.s, x.c::text, x.h::text, x.p::text,
           NULL::text, NULL::bigint
    FROM (SELECT CASE WHEN a.status ~ '^[a-z0-9_]{1,32}$' THEN a.status ELSE 'other' END AS s,
                 count(*) AS c, count(a.bundle_sha256) AS h, count(a.bundle_path) AS p
          FROM public.audit_exports a GROUP BY 1) x
    ORDER BY x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY SELECT v_t, v_at, v_v, '4 audit exports total'::text, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::text, count(*)
               FROM public.audit_exports;

  -- 5. Context only: raw payload rows, counted.
  RETURN QUERY SELECT v_t, v_at, v_v, '5 payload rows total'::text, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::text, count(p.sha256)
               FROM public.payloads p;

  RETURN QUERY SELECT v_t, v_at, v_v, 'END'::text,
                      CASE WHEN v_trunc THEN 'truncated' ELSE 'complete' END, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::bigint;
END
$fn$;

-- 6. summary.gdemo_drain_v1(...): the G-DEMO drain and authority check
-- (tmp/claude-gdemo-drain.sql draft 3, sha256 908c2829...) as fixed rows.
--   pre:  summary.gdemo_drain_v1('pre', NULL, NULL, NULL)
--   post: summary.gdemo_drain_v1('post', '2026-10-19 02:20:00+00', 3, ARRAY['b1','b2','b5'])
-- Invalid arguments raise SQLSTATE 22023 with a fixed message that never
-- echoes the input. Labels as in the psql version; the last data row is
-- CHECK (GO, or STOP with a fixed reason), then END.
CREATE FUNCTION summary.gdemo_drain_v1(phase text, start_at timestamptz,
                                       b1_attempts integer, workshop_buckets text[])
RETURNS TABLE (target text, read_at text, fn_version text, section text,
               k1 text, k2 text, k3 text, k4 text, k5 text, n bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
SET search_path = pg_catalog, pg_temp
SET "TimeZone" = 'UTC'
SET lock_timeout = '5s'
AS $fn$
#variable_conflict use_column
DECLARE
  v_t constant text := current_database();
  v_at constant text := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_v constant text := 'summary.gdemo_drain_v1';
  -- A section that reaches its row limit makes the result incomplete.
  v_n bigint;
  v_trunc boolean := false;
  v_post boolean;
  p_start timestamptz;
  p_b1 integer;
  p_buckets text[];
  d1 bigint; d2 bigint; d3 bigint;
  a_other bigint; a_not_started bigint; a_gdemo bigint; c_g_r0 bigint; a_ordinary bigint;
  v_verdict text;
BEGIN
  IF phase IS NULL OR phase NOT IN ('pre', 'post') THEN
    RAISE EXCEPTION 'invalid_argument: phase' USING ERRCODE = '22023';
  END IF;
  v_post := (phase = 'post');

  IF v_post THEN
    IF start_at IS NULL OR date_trunc('minute', start_at) <> start_at THEN
      RAISE EXCEPTION 'invalid_argument: start_at' USING ERRCODE = '22023';
    END IF;
    IF b1_attempts IS NULL OR b1_attempts NOT BETWEEN 1 AND 5 THEN
      RAISE EXCEPTION 'invalid_argument: b1_attempts' USING ERRCODE = '22023';
    END IF;
    IF workshop_buckets IS NULL
       OR cardinality(workshop_buckets) NOT BETWEEN 1 AND 5
       OR array_ndims(workshop_buckets) <> 1
       OR EXISTS (SELECT 1 FROM unnest(workshop_buckets) AS b(x)
                  WHERE b.x IS NULL OR b.x NOT IN ('b1', 'b2', 'b3', 'b4', 'b5'))
       OR workshop_buckets <> (SELECT array_agg(DISTINCT b.x ORDER BY b.x)
                               FROM unnest(workshop_buckets) AS b(x)) THEN
      RAISE EXCEPTION 'invalid_argument: workshop_buckets' USING ERRCODE = '22023';
    END IF;
    p_start := start_at; p_b1 := b1_attempts; p_buckets := workshop_buckets;
  ELSE
    IF start_at IS NOT NULL OR b1_attempts IS NOT NULL OR workshop_buckets IS NOT NULL THEN
      RAISE EXCEPTION 'invalid_argument: pre takes no terms' USING ERRCODE = '22023';
    END IF;
    -- Pre: no G-DEMO can match (0 attempts is impossible), so any
    -- G-DEMO-like grant is other_active and stops the stage.
    p_start := TIMESTAMPTZ '1970-01-01 00:00:00+00'; p_b1 := 0; p_buckets := ARRAY['none'];
  END IF;

  RETURN QUERY SELECT v_t, v_at, v_v, 'target'::text, phase, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::bigint;

  -- 1 to 3. The producer drain.
  SELECT count(*) INTO d1 FROM public.agent_runs r WHERE r.status IN ('queued', 'running');
  SELECT count(*) INTO d2 FROM public.oban_jobs j
    WHERE j.queue IN ('research', 'agent', 'integration')
      AND j.state IN ('available', 'scheduled', 'executing', 'retryable');
  SELECT count(*) INTO d3
    FROM public.model_invocations mi JOIN public.agent_runs r ON r.id = mi.agent_run_id
    WHERE mi.status IN ('reserved', 'sent') AND r.status IN ('queued', 'running');

  RETURN QUERY SELECT v_t, v_at, v_v, 'DRAIN 1 runs queued or running (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, d1;
  RETURN QUERY SELECT v_t, v_at, v_v,
    'DRAIN 2 producer jobs pending in research, agent, integration (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, d2;
  RETURN QUERY SELECT v_t, v_at, v_v,
    'DRAIN 3 reserved or sent invocations on a queued or running run (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, d3;

  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 1 runs by status'::text, x.s, NULL::text, NULL::text,
           NULL::text, NULL::text, count(*)
    FROM (SELECT CASE WHEN r.status ~ '^[a-z0-9_]{1,32}$' THEN r.status ELSE 'other' END AS s
          FROM public.agent_runs r) x
    GROUP BY x.s ORDER BY x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 2 producer jobs pending by queue and state'::text,
           j.queue, j.state::text, NULL::text, NULL::text, NULL::text, count(*)
    FROM public.oban_jobs j
    WHERE j.queue IN ('research', 'agent', 'integration')
      AND j.state IN ('available', 'scheduled', 'executing', 'retryable')
    GROUP BY j.queue, j.state ORDER BY j.queue, j.state LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 2 other queues pending (not part of the fence)'::text,
           x.q, x.st, NULL::text, NULL::text, NULL::text, count(*)
    FROM (SELECT CASE WHEN j.queue ~ '^[a-z0-9_]{1,32}$' THEN j.queue ELSE 'other' END AS q,
                 j.state::text AS st
          FROM public.oban_jobs j
          WHERE j.queue NOT IN ('research', 'agent', 'integration')
            AND j.state IN ('available', 'scheduled', 'executing', 'retryable')) x
    GROUP BY x.q, x.st ORDER BY x.q, x.st LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 3 reserved or sent invocations on a terminal run'::text,
           x.g, x.p, x.s, NULL::text, NULL::text, count(*)
    FROM (SELECT mi.ledger_generation::text AS g, mi.ledger_generation AS go,
                 CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END AS p,
                 mi.status AS s
          FROM public.model_invocations mi JOIN public.agent_runs r ON r.id = mi.agent_run_id
          WHERE mi.status IN ('reserved', 'sent') AND r.status NOT IN ('queued', 'running')) x
    GROUP BY x.g, x.go, x.p, x.s ORDER BY x.go, x.p, x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  -- 4. Authority: one classification per grant. A grant's name is never
  -- read and never authority.
  WITH a AS (
    SELECT al.grant_id, al.tenant_id, al.key, al.attempts, al.profile_id, al.available_from,
           al.available_until, al.released_at, al.applies_to,
           (SELECT array_agg(x::text ORDER BY x::text) FROM unnest(al.applies_to) AS x) AS buckets
    FROM public.model_call_allocations al
  ), g AS (
    SELECT gr.id, gr.status, gr.starts_at, gr.expires_at, gr.revoked_at,
           gr.total_attempts, gr.per_utc_day_attempts,
           (SELECT array_agg(p::text ORDER BY p::text) FROM unnest(gr.profile_ids) AS p) AS profiles,
           (SELECT count(*) FROM a WHERE a.grant_id = gr.id) AS n_alloc,
           ((SELECT count(*) FROM a WHERE a.grant_id = gr.id) = 2
            AND NOT EXISTS (SELECT 1 FROM a WHERE a.grant_id = gr.id
                            AND NOT (a.key = 'proof' AND a.buckets = ARRAY['proof']
                                     AND a.attempts = 2 AND a.released_at IS NULL))
            AND (SELECT array_agg(a.profile_id::text ORDER BY a.profile_id::text)
                 FROM a WHERE a.grant_id = gr.id)
                = ARRAY['claude_cli_opus', 'claude_cli_sonnet']) AS g_r0_allocations,
           EXISTS (SELECT 1 FROM a WHERE a.grant_id = gr.id AND a.tenant_id = gr.tenant_id
                   AND a.key = 'b1' AND a.buckets = ARRAY['b1'] AND a.profile_id IS NULL
                   AND a.attempts = p_b1
                   AND a.available_from = p_start
                   AND a.available_until = p_start + interval '60 minutes'
                   AND a.released_at IS NULL) AS b1_ok,
           EXISTS (SELECT 1 FROM a WHERE a.grant_id = gr.id AND a.tenant_id = gr.tenant_id
                   AND a.key = 'workshop' AND a.buckets = p_buckets
                   AND a.profile_id IS NULL AND a.attempts = 30
                   AND a.available_from = TIMESTAMPTZ '2026-11-06 07:00:00+00'
                   AND a.available_until IS NULL AND a.released_at IS NULL) AS workshop_ok
    FROM public.model_call_grants gr
  ), c AS (
    SELECT g.id,
           CASE
             WHEN g.status = 'revoked' THEN 'revoked'
             WHEN g.expires_at <= now() THEN 'expired'
             WHEN g.status = 'active' AND g.profiles = ARRAY['claude_cli_opus', 'claude_cli_sonnet']
                  AND g.total_attempts = 4 AND g.expires_at = TIMESTAMPTZ '2026-10-19 05:59:00+00'
                  AND g.g_r0_allocations AND g.starts_at <= now() THEN 'g_r0'
             WHEN g.status = 'active' AND g.profiles = ARRAY['claude_cli_opus', 'claude_cli_sonnet']
                  AND g.total_attempts = 4 AND g.expires_at = TIMESTAMPTZ '2026-10-19 05:59:00+00'
                  AND g.g_r0_allocations THEN 'g_r0_shape_not_started'
             WHEN g.status = 'active' AND g.revoked_at IS NULL
                  AND g.profiles = ARRAY['claude_cli_opus', 'claude_cli_sonnet']
                  AND g.total_attempts = 200 AND g.per_utc_day_attempts = 30
                  AND g.starts_at = p_start
                  AND g.expires_at = TIMESTAMPTZ '2026-11-07 06:59:00+00'
                  AND g.n_alloc = 2 AND g.b1_ok AND g.workshop_ok THEN 'gdemo'
             ELSE 'other_active'
           END AS class
    FROM g
  )
  SELECT count(*) FILTER (WHERE c.class = 'other_active'),
         count(*) FILTER (WHERE c.class = 'g_r0_shape_not_started'),
         count(*) FILTER (WHERE c.class = 'gdemo'),
         count(*) FILTER (WHERE c.class = 'g_r0'),
         (SELECT count(*) FROM public.model_call_allocations al
          JOIN c c2 ON c2.id = al.grant_id
          WHERE c2.class NOT IN ('revoked', 'expired', 'gdemo')
            AND al.applies_to && ARRAY['b1', 'b2', 'b3', 'b4', 'b5']::text[])
    INTO a_other, a_not_started, a_gdemo, c_g_r0, a_ordinary
  FROM c;

  RETURN QUERY SELECT v_t, v_at, v_v, 'AUTHORITY 4a other active unexpired grants (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, a_other;
  RETURN QUERY SELECT v_t, v_at, v_v,
    'AUTHORITY 4b G-R0-shaped grants not yet started (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, a_not_started;
  RETURN QUERY SELECT v_t, v_at, v_v,
    'AUTHORITY 4c ordinary-bucket allocations outside G-DEMO on active unexpired grants (must be 0)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, a_ordinary;
  IF v_post THEN
    RETURN QUERY SELECT v_t, v_at, v_v,
      'AUTHORITY 4d G-DEMO grants matching the reviewed terms (must be 1)'::text,
      NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, a_gdemo;
  ELSE
    RETURN QUERY SELECT v_t, v_at, v_v,
      'AUTHORITY 4d G-DEMO grants (pre: none can match; any G-DEMO-like grant counts in 4a)'::text,
      NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, a_gdemo;
  END IF;
  RETURN QUERY SELECT v_t, v_at, v_v, 'CONTEXT 4 G-R0 grants (the allowed exception)'::text,
    NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, c_g_r0;

  RETURN QUERY
    SELECT v_t, v_at, v_v,
           'CONTEXT 4 allocations of active unexpired grants by key, buckets and window state'::text,
           x.key, x.buckets, x.attempts::text, x.ws, NULL::text, count(*)
    FROM (SELECT CASE WHEN al.key ~ '^[a-z0-9_]{1,32}$' THEN al.key ELSE 'other' END AS key,
                 CASE WHEN NOT EXISTS (SELECT 1 FROM unnest(al.applies_to) AS b(x)
                                       WHERE b.x !~ '^[a-z0-9_]{1,16}$')
                      THEN al.applies_to::text ELSE 'other' END AS buckets,
                 al.attempts,
                 CASE
                   WHEN al.released_at IS NULL AND al.available_until IS NOT NULL
                        AND now() >= al.available_until THEN 'closed'
                   WHEN al.released_at IS NULL AND al.available_from IS NOT NULL
                        AND now() < al.available_from THEN 'not_yet_open'
                   ELSE 'open'
                 END AS ws
          FROM public.model_call_allocations al
          JOIN public.model_call_grants gr ON gr.id = al.grant_id
          WHERE gr.status = 'active' AND gr.expires_at > now()) x
    GROUP BY x.key, x.buckets, x.attempts, x.ws ORDER BY x.key, x.ws LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  -- 5. Context: global totals.
  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 5 invocations by generation, provider and status'::text,
           x.g, x.p, x.s, NULL::text, NULL::text, count(*)
    FROM (SELECT mi.ledger_generation::text AS g, mi.ledger_generation AS go,
                 CASE WHEN mi.provider ~ '^[a-z0-9_]{1,32}$' THEN mi.provider ELSE 'other' END AS p,
                 CASE WHEN mi.status ~ '^[a-z0-9_]{1,32}$' THEN mi.status ELSE 'other' END AS s
          FROM public.model_invocations mi) x
    GROUP BY x.g, x.go, x.p, x.s ORDER BY x.go, x.p, x.s LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  RETURN QUERY
    SELECT v_t, v_at, v_v, 'CONTEXT 5 releases by disposition'::text, x.d, NULL::text,
           NULL::text, NULL::text, NULL::text, count(*)
    FROM (SELECT CASE WHEN r.disposition ~ '^[a-z0-9_]{1,32}$' THEN r.disposition ELSE 'other' END AS d
          FROM public.model_result_releases r) x
    GROUP BY x.d ORDER BY x.d LIMIT 100;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n >= 100 THEN v_trunc := true; END IF;

  v_verdict := CASE
    WHEN v_trunc THEN 'STOP: a section reached its row limit (incomplete)'
    WHEN d1 > 0 OR d2 > 0 OR d3 > 0 THEN 'STOP: a DRAIN row is not 0'
    WHEN a_other > 0 OR a_not_started > 0 OR a_ordinary > 0 THEN 'STOP: unexpected authority'
    WHEN v_post AND a_gdemo <> 1 THEN 'STOP: G-DEMO does not match the reviewed terms exactly once'
    ELSE 'GO'
  END;
  RETURN QUERY SELECT v_t, v_at, v_v, 'CHECK'::text, v_verdict, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::bigint;
  RETURN QUERY SELECT v_t, v_at, v_v, 'END'::text,
                      CASE WHEN v_trunc THEN 'truncated' ELSE 'complete' END, NULL::text, NULL::text,
                      NULL::text, NULL::text, NULL::bigint;
END
$fn$;

-- 7. Exact signatures: no PUBLIC EXECUTE, only the login, owned by the
-- definer (the installing superuser may assign ownership; the definer gets
-- no CREATE on the schema).
REVOKE ALL ON FUNCTION summary.g3_inventory_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]) FROM PUBLIC;
ALTER FUNCTION summary.g3_inventory_v1() OWNER TO sdr_summary_definer;
ALTER FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]) OWNER TO sdr_summary_definer;
REVOKE ALL ON FUNCTION summary.g3_inventory_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION summary.g3_inventory_v1() TO sdr_summary_login;
GRANT EXECUTE ON FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]) TO sdr_summary_login;

COMMIT;
\echo END-OF-SUMMARY-INSTALL

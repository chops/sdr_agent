-- D-168 dev-database summary access: uninstall (ADR-0016). Owner-run only,
-- as a superuser, connected to sdr_agent_dev. One transaction. It removes
-- exactly what install.sql created and nothing else.
--
-- Before anything is dropped it validates the COMPLETE dependency set of
-- both roles, in every database of the cluster (pg_shdepend: every object
-- either role owns, large objects and default ACLs included, and every ACL
-- entry naming either role), the exact ACL tuples (grantor, grantee,
-- privilege, grantability) naming either role or on the summary objects,
-- the occupants of schema summary, and role memberships. Anything not created by install.sql refuses the whole
-- uninstall (psql exits 3, nothing changed), so DROP OWNED can never delete
-- or revoke something unreviewed. It does not undo optional-revoke-temp.sql.

\set ON_ERROR_STOP on

SELECT current_database() = 'sdr_agent_dev' AS right_db,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) AS is_super \gset
-- A refusal raises an error, so psql exits 3 and never prints the END marker.
\if :right_db
\else
  \echo REFUSED: connect to sdr_agent_dev. Nothing was changed.
  DO $r$ BEGIN RAISE EXCEPTION 'summary uninstall refused: wrong database'; END $r$;
\endif
\if :is_super
\else
  \echo REFUSED: uninstall needs a superuser. Nothing was changed.
  DO $r$ BEGIN RAISE EXCEPTION 'summary uninstall refused: not a superuser'; END $r$;
\endif

BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $guard$
DECLARE v_n bigint;
BEGIN
  -- Every dependency record of either role must be one install.sql made.
  WITH exp_shdep(principal, deptype, object) AS (VALUES
    ('sdr_summary_definer', 'a', 'column agent_run_id of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column applies_to of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column attempts of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column available_from of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column available_until of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column bundle_path of table public.audit_exports'),
    ('sdr_summary_definer', 'a', 'column bundle_sha256 of table public.audit_exports'),
    ('sdr_summary_definer', 'a', 'column canonical_bytes of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column disposition of table public.model_result_releases'),
    ('sdr_summary_definer', 'a', 'column event_type of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column expires_at of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column grant_id of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column id of table public.agent_runs'),
    ('sdr_summary_definer', 'a', 'column id of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column id of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column key of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column ledger_generation of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column model_invocation_id of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column model_invocation_id of table public.model_result_releases'),
    ('sdr_summary_definer', 'a', 'column payload of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column per_utc_day_attempts of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column profile_id of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column profile_id of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column profile_ids of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column provider of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column queue of table public.oban_jobs'),
    ('sdr_summary_definer', 'a', 'column released_at of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column revoked_at of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column sha256 of table public.payloads'),
    ('sdr_summary_definer', 'a', 'column starts_at of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column state of table public.oban_jobs'),
    ('sdr_summary_definer', 'a', 'column status of table public.agent_runs'),
    ('sdr_summary_definer', 'a', 'column status of table public.audit_exports'),
    ('sdr_summary_definer', 'a', 'column status of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column status of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column subject_id of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column subject_resource of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column tenant_id of table public.audit_events'),
    ('sdr_summary_definer', 'a', 'column tenant_id of table public.model_call_allocations'),
    ('sdr_summary_definer', 'a', 'column tenant_id of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'column tenant_id of table public.model_invocations'),
    ('sdr_summary_definer', 'a', 'column total_attempts of table public.model_call_grants'),
    ('sdr_summary_definer', 'a', 'schema public'),
    ('sdr_summary_definer', 'a', 'schema summary'),
    ('sdr_summary_definer', 'o', 'default privileges on new functions belonging to role sdr_summary_definer'),
    ('sdr_summary_definer', 'o', 'function summary.g3_inventory_v1()'),
    ('sdr_summary_definer', 'o', 'function summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])'),
    ('sdr_summary_login', 'a', 'database sdr_agent_dev'),
    ('sdr_summary_login', 'a', 'function summary.g3_inventory_v1()'),
    ('sdr_summary_login', 'a', 'function summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])'),
    ('sdr_summary_login', 'a', 'schema summary')
  ), act_shdep AS (
    SELECT r.rolname::text AS principal, s.deptype::text AS deptype,
           CASE WHEN s.dbid IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database()))
                THEN pg_catalog.pg_describe_object(s.classid, s.objid, s.objsubid)
                ELSE 'an object in another database (oid ' || s.dbid || ')' END AS object
    FROM pg_catalog.pg_shdepend s
    JOIN pg_catalog.pg_roles r ON r.oid = s.refobjid AND s.refclassid = 'pg_authid'::regclass
    WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  )
  SELECT count(*) INTO v_n FROM (SELECT * FROM act_shdep EXCEPT SELECT * FROM exp_shdep) x;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'REFUSED: % dependency record(s) of a summary role were not created by install.sql (owned objects, large objects, grants, or objects in another database); nothing was changed', v_n;
  END IF;

  -- Schema summary holds the two functions and nothing else.
  SELECT count(*) INTO v_n FROM pg_catalog.pg_depend d
  WHERE d.refclassid = 'pg_namespace'::regclass
    AND d.refobjid = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'summary')
    AND NOT (d.classid = 'pg_proc'::regclass
             AND d.objid IN ('summary.g3_inventory_v1()'::regprocedure,
                             'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])'::regprocedure));
  IF v_n > 0 THEN
    RAISE EXCEPTION 'REFUSED: schema summary holds % object(s) besides the two functions; nothing was changed', v_n;
  END IF;

  -- No ACL entry beyond install.sql's: no grant option, no delegation by
  -- either role.
  WITH   -- Every ACL entry (grantor, grantee, privilege, grantability) that names
-- either role, or sits on schema summary or a summary function, in this
-- database. An object owner's own entry and authority are spelled OWNER
-- (the owner itself is pinned by checks 16 and 20); PUBLIC is PUBLIC.
acl_ent AS (
  SELECT 'function' AS kind, p.oid::regprocedure::text AS obj, p.proowner AS owner, a.*
  FROM pg_catalog.pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
  UNION ALL
  SELECT 'schema', n.nspname::text, n.nspowner, a.*
  FROM pg_catalog.pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) AS a
  UNION ALL
  SELECT 'database', d.datname::text, d.datdba, a.*
  FROM pg_catalog.pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) AS a
  WHERE d.datname = current_database()
  UNION ALL
  SELECT 'relation', c.oid::regclass::text, c.relowner, a.*
  FROM pg_catalog.pg_class c, aclexplode(c.relacl) AS a
  UNION ALL
  SELECT 'column', c.oid::regclass::text || '.' || at.attname, c.relowner, a.*
  FROM pg_catalog.pg_attribute at JOIN pg_catalog.pg_class c ON c.oid = at.attrelid,
       aclexplode(at.attacl) AS a
  WHERE at.attacl IS NOT NULL
  UNION ALL
  SELECT 'default acl ' || d.defaclobjtype::text || ' in '
           || CASE WHEN d.defaclnamespace = 0 THEN '(all)' ELSE d.defaclnamespace::regnamespace::text END,
         pg_catalog.pg_get_userbyid(d.defaclrole), d.defaclrole, a.*
  FROM pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) AS a
  UNION ALL
  SELECT 'large object', m.oid::text, m.lomowner, a.*
  FROM pg_catalog.pg_largeobject_metadata m, aclexplode(m.lomacl) AS a
),
act_acl AS (
  SELECT kind, obj,
         CASE WHEN grantor = owner THEN 'OWNER' ELSE pg_catalog.pg_get_userbyid(grantor) END AS grantor,
         CASE WHEN grantee = 0 THEN 'PUBLIC' WHEN grantee = owner THEN 'OWNER'
              ELSE pg_catalog.pg_get_userbyid(grantee) END AS grantee,
         privilege_type AS privilege, CASE WHEN is_grantable THEN 't' ELSE 'f' END AS grantable
  FROM acl_ent
  WHERE grantee IN (SELECT oid FROM pg_catalog.pg_roles WHERE rolname IN ('sdr_summary_login', 'sdr_summary_definer'))
     OR grantor IN (SELECT oid FROM pg_catalog.pg_roles WHERE rolname IN ('sdr_summary_login', 'sdr_summary_definer'))
     OR (kind = 'schema' AND obj = 'summary') OR (kind = 'function' AND obj LIKE 'summary.%')
),
exp_acl(kind, obj, grantor, grantee, privilege, grantable) AS (VALUES
    ('column', 'public.agent_runs.id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.agent_runs.status', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.canonical_bytes', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.event_type', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.model_invocation_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.payload', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.subject_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.subject_resource', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_events.tenant_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_exports.bundle_path', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_exports.bundle_sha256', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.audit_exports.status', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.applies_to', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.attempts', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.available_from', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.available_until', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.grant_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.key', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.profile_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.released_at', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_allocations.tenant_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.expires_at', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.per_utc_day_attempts', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.profile_ids', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.revoked_at', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.starts_at', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.status', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.tenant_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_call_grants.total_attempts', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.agent_run_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.ledger_generation', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.profile_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.provider', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.status', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_invocations.tenant_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_result_releases.disposition', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.model_result_releases.model_invocation_id', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.oban_jobs.queue', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.oban_jobs.state', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('column', 'public.payloads.sha256', 'OWNER', 'sdr_summary_definer', 'SELECT', 'f'),
    ('database', 'sdr_agent_dev', 'OWNER', 'sdr_summary_login', 'CONNECT', 'f'),
    ('default acl f in (all)', 'sdr_summary_definer', 'OWNER', 'OWNER', 'EXECUTE', 'f'),
    ('function', 'summary.g3_inventory_v1()', 'OWNER', 'OWNER', 'EXECUTE', 'f'),
    ('function', 'summary.g3_inventory_v1()', 'OWNER', 'sdr_summary_login', 'EXECUTE', 'f'),
    ('function', 'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])', 'OWNER', 'OWNER', 'EXECUTE', 'f'),
    ('function', 'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])', 'OWNER', 'sdr_summary_login', 'EXECUTE', 'f'),
    ('schema', 'public', 'OWNER', 'sdr_summary_definer', 'USAGE', 'f'),
    ('schema', 'summary', 'OWNER', 'OWNER', 'CREATE', 'f'),
    ('schema', 'summary', 'OWNER', 'OWNER', 'USAGE', 'f'),
    ('schema', 'summary', 'OWNER', 'sdr_summary_definer', 'USAGE', 'f'),
    ('schema', 'summary', 'OWNER', 'sdr_summary_login', 'USAGE', 'f')
)
  SELECT count(*) INTO v_n FROM (SELECT * FROM act_acl EXCEPT SELECT * FROM exp_acl) x;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'REFUSED: % ACL entr(y/ies) naming a summary role or on the summary objects were not created by install.sql (grant options or delegated grants); nothing was changed', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM pg_catalog.pg_auth_members am
  JOIN pg_catalog.pg_roles r ON r.oid IN (am.member, am.roleid)
  WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'REFUSED: a summary role has % role membership(s); nothing was changed', v_n;
  END IF;
END
$guard$;

DROP FUNCTION summary.g3_inventory_v1();
DROP FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]);
DROP SCHEMA summary;
-- Only what the guard above enumerated remains: the CONNECT, schema USAGE
-- and column SELECT grants and the definer's default-privilege entry.
DROP OWNED BY sdr_summary_login, sdr_summary_definer;
DROP ROLE sdr_summary_login;
DROP ROLE sdr_summary_definer;

COMMIT;
\echo END-OF-SUMMARY-UNINSTALL

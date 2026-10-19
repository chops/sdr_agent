-- ADR-0016 installed-state attestation for the dev DB summary-access role.
-- Owner-run, read-only: one REPEATABLE READ, READ ONLY transaction over
-- catalogs and privilege functions. It never reads a table row.
--
-- Run (as the owner superuser, connected to sdr_agent_dev):
--   psql -X -q -v ON_ERROR_STOP=1 -d sdr_agent_dev -f attest.sql
--
-- The verdict is machine-checked. Every check row reads
-- "<check> (must be <expected>)|<actual>" and carries "|FAILED" when it does
-- not hold. Acceptance requires ALL of: psql exit 0, no FAILED row, and the
-- last line END-OF-SUMMARY-ATTEST. On any failed check it prints ATTEST
-- REFUSED, rolls back and exits 3 (ON_ERROR_STOP): do not activate agent
-- use. The rows before the checks are inventory for the reviewer.
--
-- What the checks pin (ADR-0016 "Installed-state acceptance"):
--   * role attributes, connection limits and the exact session defaults;
--   * no role membership in either direction, so has_*_privilege() below
--     is the complete effective privilege (direct, PUBLIC, ownership), and
--     the "reach" set also folds in any membership if one ever appears;
--   * the exact set of dependency records (pg_shdepend: every ownership
--     and every explicit ACL entry of either role, in EVERY database of the
--     cluster, large objects included);
--   * the definer's exact effective SELECT columns, and nothing else;
--   * no table, column, sequence or large-object privilege for the login,
--     from any route (PUBLIC included);
--   * every function either role can execute, by any route: no SECURITY
--     DEFINER function except the two summary functions, and no
--     untrusted-language function outside pg_catalog that is not part of a
--     reviewed extension; the reviewed server-file/admin built-ins denied;
--   * the summary schema's owner, ACL and occupants, the functions' exact
--     shape, ACL, settings, result type and prosrc SHA-256 (pinned below);
--   * the exact default ACLs naming either role; the extension set;
--   * the exact ACL entries naming either role or on the summary objects,
--     as full (grantor, grantee, privilege, grantability) tuples, so a
--     WITH GRANT OPTION widening of an allowed grant is refused; an
--     owner's own entry is modeled as OWNER, its implicit rights untouched.
-- It changes nothing and revokes nothing shared. Re-run after install,
-- after any CREATE OR REPLACE, ALTER, GRANT or REVOKE touching these roles,
-- the schema or the functions, and after a PostgreSQL major upgrade.

\set ON_ERROR_STOP on
\pset footer off
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
-- Object descriptions are schema-qualified and comparisons collation-free.
SET LOCAL search_path = pg_catalog, pg_temp;

SELECT 'target' AS section, current_database() AS database,
       current_setting('server_version') AS server_version,
       (SELECT system_identifier FROM pg_catalog.pg_control_system()) AS system_identifier,
       to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS read_at_utc;

-- ---------------------------------------------------------------- inventory
SELECT 'A roles' AS section, r.rolname, r.rolcanlogin, r.rolsuper, r.rolinherit,
       r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolbypassrls,
       r.rolconnlimit, r.rolvaliduntil, r.rolconfig
FROM pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY r.rolname;

-- Settings every role inherits in this database (ALTER DATABASE ... SET).
SELECT 'A database-wide settings (all roles)' AS section, d.datname, s.setconfig
FROM pg_catalog.pg_db_role_setting s
JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
WHERE s.setrole = 0 ORDER BY 2;

SELECT 'C effective database privileges (PUBLIC-derived; OPEN owner choices)' AS section,
       d.datname, r.rolname,
       has_database_privilege(r.oid, d.oid, 'CONNECT') AS can_connect,
       has_database_privilege(r.oid, d.oid, 'TEMP') AS can_temp,
       has_database_privilege(r.oid, d.oid, 'CREATE') AS can_create
FROM pg_catalog.pg_database d
CROSS JOIN pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer') AND d.datallowconn
ORDER BY 2, 3;

SELECT 'E definer column privileges' AS section, c.oid::regclass::text AS relation,
       string_agg(a.attname, ',' ORDER BY a.attname COLLATE "C") AS select_columns
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_column_privilege('sdr_summary_definer', c.oid, a.attnum, 'SELECT')
GROUP BY 2 ORDER BY 2;

-- Full SHA-256 of each summary function's source and full definition.
-- prosrc_sha256 is pinned in the checks below; functiondef_sha256 depends
-- on the server's formatting and is compared with the reviewed record.
SELECT 'G summary functions' AS section, p.oid::regprocedure::text AS signature,
       pg_catalog.pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer,
       p.provolatile AS volatility, p.proparallel AS parallel, p.proleakproof AS leakproof,
       l.lanname AS language, p.proconfig, p.proacl::text AS proacl,
       encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') AS prosrc_sha256,
       encode(sha256(convert_to(pg_catalog.pg_get_functiondef(p.oid), 'UTF8')), 'hex')
         AS functiondef_sha256
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'summary'
ORDER BY 2;

-- Every privileged function either role can execute, by any route:
-- SECURITY DEFINER, or an untrusted language outside pg_catalog and not
-- part of the reviewed citext extension. Only the two summary functions
-- may appear (checks 25 and 26 below enforce it).
SELECT 'H privileged functions callable by either role' AS section, r.rolname,
       p.oid::regprocedure::text AS signature, pg_catalog.pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef AS security_definer, l.lanname AS language
FROM pg_catalog.pg_roles r
JOIN pg_catalog.pg_roles via ON pg_has_role(r.oid, via.oid, 'MEMBER')
CROSS JOIN pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  AND (p.prosecdef
       OR (NOT l.lanpltrusted AND n.nspname <> 'pg_catalog'
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                           JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
                           WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                             AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                             AND e.extname IN ('citext'))))
  AND has_function_privilege(via.oid, p.oid, 'EXECUTE')
GROUP BY 2, 3, 4, 5, 6 ORDER BY 2, 3 LIMIT 200;

SELECT 'I default acl' AS section, pg_catalog.pg_get_userbyid(d.defaclrole) AS for_role,
       coalesce(n.nspname, '(all)') AS schema, d.defaclobjtype AS objtype,
       d.defaclacl::text AS defaclacl
FROM pg_catalog.pg_default_acl d
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
ORDER BY 2, 3, 4;

SELECT 'J large objects' AS section, count(*) AS rows,
       count(*) FILTER (WHERE m.lomacl IS NOT NULL) AS with_explicit_acl
FROM pg_catalog.pg_largeobject_metadata m;

-- PUBLIC by default; each acts only on the caller's own role's sessions
-- unless the caller holds pg_signal_backend (membership is checked 0).
SELECT 'K backend-signal functions executable by login (own sessions only)' AS section,
       p.oid::regprocedure::text
FROM pg_catalog.pg_proc p
WHERE p.pronamespace = 'pg_catalog'::regnamespace
  AND p.proname IN ('pg_cancel_backend', 'pg_terminate_backend')
  AND has_function_privilege('sdr_summary_login', p.oid, 'EXECUTE')
ORDER BY 2;

SELECT 'L extensions' AS section, e.extname, e.extversion
FROM pg_catalog.pg_extension e ORDER BY 2;

SELECT 'M dependency records of either role' AS section, r.rolname, s.deptype,
       CASE WHEN s.dbid IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database()))
            THEN pg_catalog.pg_describe_object(s.classid, s.objid, s.objsubid)
            ELSE 'an object in another database (oid ' || s.dbid || ')' END AS object
FROM pg_catalog.pg_shdepend s
JOIN pg_catalog.pg_roles r ON r.oid = s.refobjid AND s.refclassid = 'pg_authid'::regclass
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY 2, 3, 4;

-- ------------------------------------------------------------------- checks
WITH
roles AS (
  SELECT r.oid, r.rolname FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
),
-- Each principal and every role whose privileges it could use (itself
-- plus any membership, inherited or SET-only).
reach AS (
  SELECT r.rolname AS principal, g.oid AS via
  FROM roles r JOIN pg_catalog.pg_roles g ON pg_has_role(r.oid, g.oid, 'MEMBER')
),
exp_shdep(principal, deptype, object) AS (VALUES
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
),
act_shdep AS (
  SELECT r.rolname AS principal, s.deptype::text AS deptype,
         CASE WHEN s.dbid IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database()))
              THEN pg_catalog.pg_describe_object(s.classid, s.objid, s.objsubid)
              ELSE 'an object in another database (oid ' || s.dbid || ')' END AS object
  FROM pg_catalog.pg_shdepend s
  JOIN roles r ON r.oid = s.refobjid AND s.refclassid = 'pg_authid'::regclass
),
exp_cols(rel, col) AS (VALUES
    ('public.agent_runs', 'id'),
    ('public.agent_runs', 'status'),
    ('public.audit_events', 'canonical_bytes'),
    ('public.audit_events', 'event_type'),
    ('public.audit_events', 'model_invocation_id'),
    ('public.audit_events', 'payload'),
    ('public.audit_events', 'subject_id'),
    ('public.audit_events', 'subject_resource'),
    ('public.audit_events', 'tenant_id'),
    ('public.audit_exports', 'bundle_path'),
    ('public.audit_exports', 'bundle_sha256'),
    ('public.audit_exports', 'status'),
    ('public.model_call_allocations', 'applies_to'),
    ('public.model_call_allocations', 'attempts'),
    ('public.model_call_allocations', 'available_from'),
    ('public.model_call_allocations', 'available_until'),
    ('public.model_call_allocations', 'grant_id'),
    ('public.model_call_allocations', 'key'),
    ('public.model_call_allocations', 'profile_id'),
    ('public.model_call_allocations', 'released_at'),
    ('public.model_call_allocations', 'tenant_id'),
    ('public.model_call_grants', 'expires_at'),
    ('public.model_call_grants', 'id'),
    ('public.model_call_grants', 'per_utc_day_attempts'),
    ('public.model_call_grants', 'profile_ids'),
    ('public.model_call_grants', 'revoked_at'),
    ('public.model_call_grants', 'starts_at'),
    ('public.model_call_grants', 'status'),
    ('public.model_call_grants', 'tenant_id'),
    ('public.model_call_grants', 'total_attempts'),
    ('public.model_invocations', 'agent_run_id'),
    ('public.model_invocations', 'id'),
    ('public.model_invocations', 'ledger_generation'),
    ('public.model_invocations', 'profile_id'),
    ('public.model_invocations', 'provider'),
    ('public.model_invocations', 'status'),
    ('public.model_invocations', 'tenant_id'),
    ('public.model_result_releases', 'disposition'),
    ('public.model_result_releases', 'model_invocation_id'),
    ('public.oban_jobs', 'queue'),
    ('public.oban_jobs', 'state'),
    ('public.payloads', 'sha256')
),
act_cols AS (
  SELECT c.oid::regclass::text AS rel, a.attname::text AS col
  FROM pg_catalog.pg_attribute a
  JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
    AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
    AND has_column_privilege('sdr_summary_definer', c.oid, a.attnum, 'SELECT')
),
callable AS (
  SELECT DISTINCT r.principal, p.oid, p.oid::regprocedure::text AS sig, p.prosecdef,
         l.lanpltrusted, n.nspname,
         EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                 JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
                 WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                   AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                   AND e.extname IN ('citext')) AS in_reviewed_extension
  FROM reach r
  CROSS JOIN pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_catalog.pg_language l ON l.oid = p.prolang
  WHERE has_function_privilege(r.via, p.oid, 'EXECUTE')
),
-- Every ACL entry (grantor, grantee, privilege, grantability) that names
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
),
summary_fns AS (
  SELECT p.* FROM pg_catalog.pg_proc p WHERE p.pronamespace = 'summary'::regnamespace
),
c(ord, name, expected, actual) AS (
  SELECT 1, 'A roles present', '2', (SELECT count(*)::text FROM roles)
  UNION ALL
  SELECT 2, 'A role attributes as installed', 'login:LOGIN,NOINHERIT,limit=2;definer:NOLOGIN,NOINHERIT,limit=-1',
         (SELECT string_agg(format('%s:%s,%s,limit=%s%s',
                   replace(r.rolname, 'sdr_summary_', ''),
                   CASE WHEN r.rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
                   CASE WHEN r.rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END,
                   r.rolconnlimit,
                   CASE WHEN r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication
                             OR r.rolbypassrls OR r.rolvaliduntil IS NOT NULL
                        THEN ',EXTRA-ATTRIBUTE' ELSE '' END),
                 ';' ORDER BY r.rolname COLLATE "C" DESC)
          FROM pg_catalog.pg_roles r
          WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer'))
  UNION ALL
  SELECT 3, 'A login session defaults (sorted)',
         'default_transaction_read_only=on,idle_in_transaction_session_timeout=60s,lock_timeout=5s,search_path=pg_catalog,statement_timeout=60s',
         (SELECT coalesce(string_agg(x, ',' ORDER BY x COLLATE "C"), '(none)')
          FROM pg_catalog.pg_roles r, unnest(r.rolconfig) AS x WHERE r.rolname = 'sdr_summary_login')
  UNION ALL
  SELECT 4, 'A definer session defaults', '(none)',
         (SELECT coalesce(string_agg(x, ',' ORDER BY x COLLATE "C"), '(none)')
          FROM pg_catalog.pg_roles r, unnest(r.rolconfig) AS x WHERE r.rolname = 'sdr_summary_definer')
  UNION ALL
  SELECT 5, 'A per-database settings for either role', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_db_role_setting s JOIN roles r ON r.oid = s.setrole
          WHERE s.setdatabase <> 0)
  UNION ALL
  SELECT 6, 'B role memberships of either role, in either direction', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_auth_members am
          WHERE am.member IN (SELECT oid FROM roles) OR am.roleid IN (SELECT oid FROM roles))
  UNION ALL
  SELECT 7, 'M dependency records (ownership, ACL; every database) not on the reviewed list', '0',
         (SELECT count(*)::text FROM (SELECT * FROM act_shdep EXCEPT SELECT * FROM exp_shdep) x)
  UNION ALL
  SELECT 8, 'M reviewed dependency records missing', '0',
         (SELECT count(*)::text FROM (SELECT * FROM exp_shdep EXCEPT SELECT * FROM act_shdep) x)
  UNION ALL
  SELECT 9, 'E definer SELECT columns not on the reviewed list', '0',
         (SELECT count(*)::text FROM (SELECT * FROM act_cols EXCEPT SELECT * FROM exp_cols) x)
  UNION ALL
  SELECT 10, 'E reviewed definer SELECT columns missing', '0',
         (SELECT count(*)::text FROM (SELECT * FROM exp_cols EXCEPT SELECT * FROM act_cols) x)
  UNION ALL
  SELECT 11, 'E definer column INSERT, UPDATE or REFERENCES', '0',
         (SELECT count(*)::text
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_class cl ON cl.oid = a.attrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
          CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'REFERENCES']) AS p(priv)
          WHERE cl.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
            AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
            AND has_column_privilege('sdr_summary_definer', cl.oid, a.attnum, p.priv))
  UNION ALL
  SELECT 12, 'E table-level or sequence privileges of either role (any route)', '0',
         (SELECT count(*)::text
          FROM roles r
          CROSS JOIN pg_catalog.pg_class cl
          JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
          CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES',
                                  'TRIGGER', 'MAINTAIN', 'USAGE']) AS p(priv)
          WHERE cl.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
            AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
            AND CASE WHEN cl.relkind = 'S'
                     THEN p.priv IN ('USAGE', 'SELECT', 'UPDATE')
                          AND has_sequence_privilege(r.oid, cl.oid, p.priv)
                     ELSE p.priv <> 'USAGE' AND has_table_privilege(r.oid, cl.oid, p.priv) END)
  UNION ALL
  SELECT 13, 'E login column privileges (any route)', '0',
         (SELECT count(*)::text
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_class cl ON cl.oid = a.attrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
          CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) AS p(priv)
          WHERE cl.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
            AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
            AND has_column_privilege('sdr_summary_login', cl.oid, a.attnum, p.priv))
  UNION ALL
  SELECT 14, 'C database CREATE for either role (any database)', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_database d CROSS JOIN roles r
          WHERE has_database_privilege(r.oid, d.oid, 'CREATE'))
  UNION ALL
  SELECT 15, 'D schema CREATE for either role', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_namespace n CROSS JOIN roles r
          WHERE has_schema_privilege(r.oid, n.oid, 'CREATE'))
  UNION ALL
  SELECT 16, 'F summary schema owned by a superuser', 'true',
         (SELECT coalesce(bool_and(o.rolsuper), false)::text FROM pg_catalog.pg_namespace n
          JOIN pg_catalog.pg_roles o ON o.oid = n.nspowner WHERE n.nspname = 'summary')
  UNION ALL
  SELECT 17, 'F summary schema grants other than the owner''s', 'sdr_summary_definer:USAGE,sdr_summary_login:USAGE',
         (SELECT string_agg(x, ',' ORDER BY x COLLATE "C") FROM (
            SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(a.grantee) END
                   || ':' || a.privilege_type AS x
            FROM pg_catalog.pg_namespace n
            CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) AS a
            WHERE n.nspname = 'summary' AND a.grantee <> n.nspowner) y)
  UNION ALL
  SELECT 18, 'F objects in schema summary other than the two functions', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_depend d
          WHERE d.refclassid = 'pg_namespace'::regclass AND d.refobjid = 'summary'::regnamespace
            AND NOT (d.classid = 'pg_proc'::regclass
                     AND d.objid IN (SELECT oid FROM summary_fns
                                     WHERE oid::regprocedure::text IN (
                                       'summary.g3_inventory_v1()',
                                       'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])'))))
  UNION ALL
  SELECT 19, 'G summary functions present', '2', (SELECT count(*)::text FROM summary_fns)
  UNION ALL
  SELECT 20, 'G summary function shape violations (owner, SECURITY DEFINER, STABLE, PARALLEL UNSAFE, not leakproof, plpgsql, settings, result type)', '0',
         (SELECT count(*)::text FROM summary_fns p
          JOIN pg_catalog.pg_language l ON l.oid = p.prolang
          WHERE p.oid::regprocedure::text NOT IN (
                  'summary.g3_inventory_v1()',
                  'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])')
             OR pg_catalog.pg_get_userbyid(p.proowner) <> 'sdr_summary_definer'
             OR NOT p.prosecdef OR p.provolatile <> 's' OR p.proparallel <> 'u' OR p.proleakproof
             OR l.lanname <> 'plpgsql'
             OR (SELECT string_agg(x, ',' ORDER BY x COLLATE "C") FROM unnest(p.proconfig) AS x)
                IS DISTINCT FROM 'TimeZone=UTC,lock_timeout=5s,search_path=pg_catalog, pg_temp'
             OR pg_catalog.pg_get_function_result(p.oid) <> 'TABLE(target text, read_at text, fn_version text, section text, k1 text, k2 text, k3 text, k4 text, k5 text, n bigint)')
  UNION ALL
  SELECT 21, 'G summary function grants (both functions)', 'sdr_summary_definer:EXECUTE,sdr_summary_login:EXECUTE',
         (SELECT string_agg(x, ',' ORDER BY x COLLATE "C") FROM (
            SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(a.grantee) END
                   || ':' || a.privilege_type AS x
            FROM summary_fns p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a) y)
  UNION ALL
  SELECT 22, 'G summary function grant sets identical', '1',
         (SELECT count(DISTINCT (SELECT string_agg(x, ',' ORDER BY x COLLATE "C") FROM (
                                   SELECT a.grantee::text || ':' || a.privilege_type AS x
                                   FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a) y))::text
          FROM summary_fns p)
  UNION ALL
  SELECT 23, 'G g3_inventory_v1 prosrc sha256', '6357e1d4bd6bbd2038a0f07ff5f1ca8601ba1f864a24c28db8623859a527ea65',
         (SELECT encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') FROM summary_fns p
          WHERE p.oid::regprocedure::text = 'summary.g3_inventory_v1()')
  UNION ALL
  SELECT 24, 'G gdemo_drain_v1 prosrc sha256', 'b6cc57a9dbe7154ee9f400821670e10035ae9bb7a63fb969389d9a5c4d6142b8',
         (SELECT encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') FROM summary_fns p
          WHERE p.oid::regprocedure::text = 'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])')
  UNION ALL
  SELECT 25, 'X SECURITY DEFINER functions callable by either role other than the two summary functions (any schema; direct, inherited, owned or PUBLIC)', '0',
         (SELECT count(*)::text FROM callable
          WHERE prosecdef AND sig NOT IN (
            'summary.g3_inventory_v1()',
            'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])'))
  UNION ALL
  SELECT 26, 'X untrusted-language functions outside pg_catalog callable by either role and not in a reviewed extension', '0',
         (SELECT count(*)::text FROM callable
          WHERE NOT lanpltrusted AND nspname <> 'pg_catalog' AND NOT in_reviewed_extension)
  UNION ALL
  SELECT 27, 'X summary functions callable, per role', 'sdr_summary_definer:2,sdr_summary_login:2',
         (SELECT string_agg(principal || ':' || n, ',' ORDER BY principal COLLATE "C") FROM (
            SELECT principal, count(*) AS n FROM callable WHERE nspname = 'summary' GROUP BY 1) x)
  UNION ALL
  -- (The replication-slot functions are PUBLIC-executable but require the
  -- REPLICATION attribute, which check 2 pins off.)
  SELECT 28, 'K server-file, admin and remote-connection built-ins callable by either role', '0',
         (SELECT count(*)::text FROM callable cf JOIN pg_catalog.pg_proc p ON p.oid = cf.oid
          WHERE p.proname IN ('pg_read_file', 'pg_read_binary_file', 'pg_ls_dir', 'pg_stat_file',
                              'lo_import', 'lo_export', 'pg_reload_conf', 'pg_rotate_logfile',
                              'pg_ls_logdir', 'pg_ls_waldir', 'pg_ls_tmpdir', 'pg_ls_archive_statusdir',
                              'pg_ls_logicalsnapdir', 'pg_ls_logicalmapdir', 'pg_ls_replslotdir',
                              'pg_promote', 'pg_switch_wal', 'pg_create_restore_point',
                              'pg_backup_start', 'pg_backup_stop', 'pg_log_backend_memory_contexts',
                              'dblink_connect', 'dblink_connect_u', 'dblink', 'dblink_exec'))
  UNION ALL
  SELECT 29, 'I default ACLs naming either role', 'sdr_summary_definer|(all)|f|sdr_summary_definer:EXECUTE',
         (SELECT string_agg(row_text, ';' ORDER BY row_text COLLATE "C") FROM (
            SELECT format('%s|%s|%s|%s', pg_catalog.pg_get_userbyid(d.defaclrole),
                          CASE WHEN d.defaclnamespace = 0 THEN '(all)' ELSE d.defaclnamespace::regnamespace::text END, d.defaclobjtype,
                          (SELECT string_agg(x, ',' ORDER BY x COLLATE "C") FROM (
                             SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                                         ELSE pg_catalog.pg_get_userbyid(a.grantee) END
                                    || ':' || a.privilege_type AS x
                             FROM aclexplode(d.defaclacl) AS a) y)) AS row_text
            FROM pg_catalog.pg_default_acl d
            WHERE d.defaclrole IN (SELECT oid FROM roles)
               OR EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) AS a
                          WHERE a.grantee IN (SELECT oid FROM roles))) x)
  UNION ALL
  SELECT 30, 'J large objects owned by either role', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_largeobject_metadata m
          WHERE m.lomowner IN (SELECT oid FROM roles))
  UNION ALL
  SELECT 31, 'J large objects readable or writable by either role', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_largeobject_metadata m CROSS JOIN roles r
          WHERE has_largeobject_privilege(r.oid, m.oid, 'SELECT')
             OR has_largeobject_privilege(r.oid, m.oid, 'UPDATE'))
  UNION ALL
  SELECT 32, 'J lo_compat_privileges', 'off', current_setting('lo_compat_privileges')
  UNION ALL
  SELECT 33, 'L extensions other than plpgsql and citext', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_extension e WHERE e.extname NOT IN ('plpgsql', 'citext'))
  UNION ALL
  SELECT 34, 'N ACL entries (grantor, grantee, privilege, grantability) not on the reviewed list', '0',
         (SELECT count(*)::text FROM (SELECT * FROM act_acl EXCEPT SELECT * FROM exp_acl) x)
  UNION ALL
  SELECT 35, 'N reviewed ACL entries missing', '0',
         (SELECT count(*)::text FROM (SELECT * FROM exp_acl EXCEPT SELECT * FROM act_acl) x)
  UNION ALL
  SELECT 36, 'N grant options held by either role (WITH GRANT OPTION; ownership excluded)', '0',
         (SELECT count(*)::text FROM act_acl WHERE grantable = 't' AND grantee <> 'OWNER')
)
SELECT string_agg(format('%s (must be %s)|%s%s', name, expected, coalesce(actual, '(null)'),
                         CASE WHEN actual IS DISTINCT FROM expected THEN '|FAILED' ELSE '' END),
                  E'\n' ORDER BY ord) AS attest_report,
       count(*) FILTER (WHERE actual IS DISTINCT FROM expected) AS attest_failed,
       count(*) AS attest_checks,
       count(*) FILTER (WHERE actual IS DISTINCT FROM expected) = 0 AS attest_ok
FROM c \gset

\echo :attest_report
\if :attest_ok
  COMMIT;
  \echo ATTEST PASS: :attest_checks of :attest_checks checks hold
  \echo END-OF-SUMMARY-ATTEST
\else
  \echo ATTEST REFUSED: :attest_failed of :attest_checks checks failed (rows marked FAILED). Do not activate agent use.
  ROLLBACK;
  DO $r$ BEGIN RAISE EXCEPTION 'summary attestation refused'; END $r$;
\endif

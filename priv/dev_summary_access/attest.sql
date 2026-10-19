-- ADR-0016 installed-state attestation for the dev DB summary-access role.
-- Owner-run, read-only. It changes nothing: one REPEATABLE READ, READ ONLY
-- transaction over catalogs and privilege functions only. It never reads a
-- table row.
-- Run: psql -X -q -v ON_ERROR_STOP=1 -d sdr_agent_dev -f attest.sql
-- Complete only when psql exits 0 AND the last line is
-- END-OF-SUMMARY-ATTEST. Re-run after install and after any CREATE OR
-- REPLACE, ALTER or GRANT touching the roles, schema or functions; compare
-- the function hashes with the reviewed install.sql.
-- Rows whose section says "(must be ...)" are the checks; everything else
-- is inventory for the reviewer.

\set ON_ERROR_STOP on
\pset footer off
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

SELECT 'target' AS section, current_database() AS database,
       current_setting('server_version') AS server_version,
       to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS read_at_utc;

-- A. Role attributes and session defaults.
SELECT 'A roles' AS section, r.rolname, r.rolcanlogin, r.rolsuper, r.rolinherit,
       r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolbypassrls,
       r.rolconnlimit, r.rolvaliduntil, r.rolconfig
FROM pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY r.rolname;

SELECT 'A roles present (must be 2)' AS section, count(*) AS rows
FROM pg_catalog.pg_roles WHERE rolname IN ('sdr_summary_login', 'sdr_summary_definer');

SELECT 'A role attribute violations (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  AND (r.rolsuper OR r.rolinherit OR r.rolcreaterole OR r.rolcreatedb
       OR r.rolreplication OR r.rolbypassrls
       OR (r.rolname = 'sdr_summary_definer' AND r.rolcanlogin)
       OR (r.rolname = 'sdr_summary_login' AND NOT r.rolcanlogin));

-- Per-database role settings (ALTER ROLE ... IN DATABASE) also apply.
SELECT 'A per-database role settings' AS section, r.rolname,
       coalesce(d.datname, '(all)') AS database, s.setconfig
FROM pg_catalog.pg_db_role_setting s
JOIN pg_catalog.pg_roles r ON r.oid = s.setrole
LEFT JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY 2, 3;

-- B. Memberships in either direction. The login must be a member of
-- nothing, and nothing may be a member of the definer.
SELECT 'B memberships' AS section, m.rolname AS member, g.rolname AS granted_role,
       am.admin_option, am.inherit_option, am.set_option, gr.rolname AS grantor
FROM pg_catalog.pg_auth_members am
JOIN pg_catalog.pg_roles m ON m.oid = am.member
JOIN pg_catalog.pg_roles g ON g.oid = am.roleid
JOIN pg_catalog.pg_roles gr ON gr.oid = am.grantor
WHERE m.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
   OR g.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY 2, 3;

SELECT 'B login memberships (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_auth_members am
JOIN pg_catalog.pg_roles m ON m.oid = am.member
WHERE m.rolname = 'sdr_summary_login';

SELECT 'B members of definer, other than the bootstrap superuser (must be 0)' AS section,
       count(*) AS rows
FROM pg_catalog.pg_auth_members am
JOIN pg_catalog.pg_roles g ON g.oid = am.roleid
JOIN pg_catalog.pg_roles m ON m.oid = am.member
WHERE g.rolname = 'sdr_summary_definer' AND NOT m.rolsuper;

-- C. Database privileges, effective (PUBLIC included) for every database
-- on the cluster: CONNECT elsewhere and TEMP here are known residuals.
SELECT 'C database acl' AS section, d.datname, d.datacl::text AS datacl
FROM pg_catalog.pg_database d ORDER BY d.datname;

SELECT 'C effective database privileges' AS section, d.datname, r.rolname,
       has_database_privilege(r.oid, d.oid, 'CONNECT') AS can_connect,
       has_database_privilege(r.oid, d.oid, 'TEMP') AS can_temp,
       has_database_privilege(r.oid, d.oid, 'CREATE') AS can_create
FROM pg_catalog.pg_database d
CROSS JOIN pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer') AND d.datallowconn
ORDER BY 2, 3;

SELECT 'C database CREATE for either role (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_database d CROSS JOIN pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  AND has_database_privilege(r.oid, d.oid, 'CREATE');

-- D. Schema privileges, effective, for every non-system schema.
SELECT 'D schema acl' AS section, n.nspname, pg_catalog.pg_get_userbyid(n.nspowner) AS owner,
       n.nspacl::text AS nspacl
FROM pg_catalog.pg_namespace n
WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
ORDER BY n.nspname;

SELECT 'D effective schema privileges' AS section, n.nspname, r.rolname,
       has_schema_privilege(r.oid, n.oid, 'USAGE') AS usage,
       has_schema_privilege(r.oid, n.oid, 'CREATE') AS can_create
FROM pg_catalog.pg_namespace n CROSS JOIN pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND (has_schema_privilege(r.oid, n.oid, 'USAGE') OR has_schema_privilege(r.oid, n.oid, 'CREATE'))
ORDER BY 2, 3;

SELECT 'D schema CREATE for either role (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_namespace n CROSS JOIN pg_catalog.pg_roles r
WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
  AND has_schema_privilege(r.oid, n.oid, 'CREATE');

-- E. Relation and column privileges, effective (PUBLIC included), outside
-- the system schemas. The login holds none; the definer holds column
-- SELECT only, on the reviewed list.
SELECT 'E login relation privileges (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES',
                        'TRIGGER', 'MAINTAIN']) AS p(priv)
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_table_privilege('sdr_summary_login', c.oid, p.priv);

SELECT 'E login column privileges (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) AS p(priv)
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_column_privilege('sdr_summary_login', c.oid, a.attnum, p.priv);

SELECT 'E login sequence privileges (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) AS p(priv)
WHERE c.relkind = 'S'
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_sequence_privilege('sdr_summary_login', c.oid, p.priv);

SELECT 'E definer relation privileges other than column SELECT (must be 0)' AS section,
       count(*) AS rows
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES',
                        'TRIGGER', 'MAINTAIN']) AS p(priv)
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND CASE WHEN c.relkind = 'S' THEN p.priv IN ('SELECT', 'UPDATE')
             AND has_sequence_privilege('sdr_summary_definer', c.oid, p.priv)
           ELSE has_table_privilege('sdr_summary_definer', c.oid, p.priv) END;

SELECT 'E definer column privileges' AS section, n.nspname, c.relname, p.priv,
       string_agg(a.attname, ',' ORDER BY a.attname) AS columns
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) AS p(priv)
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_column_privilege('sdr_summary_definer', c.oid, a.attnum, p.priv)
GROUP BY 2, 3, 4 ORDER BY 2, 3, 4;

SELECT 'E definer column privileges other than SELECT (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'REFERENCES']) AS p(priv)
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND has_column_privilege('sdr_summary_definer', c.oid, a.attnum, p.priv);

-- F. Objects either role owns. Only the two summary functions.
SELECT 'F owned objects' AS section, 'relation' AS kind, c.oid::regclass::text AS object
FROM pg_catalog.pg_class c
WHERE pg_catalog.pg_get_userbyid(c.relowner) IN ('sdr_summary_login', 'sdr_summary_definer')
UNION ALL
SELECT 'F owned objects', 'function', p.oid::regprocedure::text
FROM pg_catalog.pg_proc p
WHERE pg_catalog.pg_get_userbyid(p.proowner) IN ('sdr_summary_login', 'sdr_summary_definer')
UNION ALL
SELECT 'F owned objects', 'schema', n.nspname::text
FROM pg_catalog.pg_namespace n
WHERE pg_catalog.pg_get_userbyid(n.nspowner) IN ('sdr_summary_login', 'sdr_summary_definer')
UNION ALL
SELECT 'F owned objects', 'type', t.oid::regtype::text
FROM pg_catalog.pg_type t
WHERE pg_catalog.pg_get_userbyid(t.typowner) IN ('sdr_summary_login', 'sdr_summary_definer')
  AND t.typrelid = 0 AND t.typelem = 0
ORDER BY 2, 3;

SELECT 'F objects owned by the login (must be 0)' AS section, count(*) AS rows
FROM (SELECT relowner AS o FROM pg_catalog.pg_class
      UNION ALL SELECT proowner FROM pg_catalog.pg_proc
      UNION ALL SELECT nspowner FROM pg_catalog.pg_namespace
      UNION ALL SELECT typowner FROM pg_catalog.pg_type) x
WHERE pg_catalog.pg_get_userbyid(x.o) = 'sdr_summary_login';

-- G. Every function in schema summary: exact signature, owner, security,
-- settings, volatility, ACL, and hashes of its source and full definition.
SELECT 'G summary functions' AS section, p.oid::regprocedure::text AS signature,
       pg_catalog.pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer,
       p.provolatile AS volatility, p.proparallel AS parallel, p.proleakproof AS leakproof,
       l.lanname AS language, p.proconfig, p.proacl::text AS proacl,
       md5(p.prosrc) AS prosrc_md5,
       encode(sha256(convert_to(p.prosrc, 'UTF8')), 'hex') AS prosrc_sha256,
       encode(sha256(convert_to(pg_catalog.pg_get_functiondef(p.oid), 'UTF8')), 'hex')
         AS functiondef_sha256
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'summary'
ORDER BY 2;

SELECT 'G summary functions present (must be 2)' AS section, count(*) AS rows
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'summary';

SELECT 'G summary function shape violations (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'summary'
  AND (p.oid::regprocedure::text NOT IN (
         'summary.g3_inventory_v1()',
         'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])')
       OR pg_catalog.pg_get_userbyid(p.proowner) <> 'sdr_summary_definer'
       OR NOT p.prosecdef
       OR p.provolatile <> 's'
       OR NOT ('search_path=pg_catalog, pg_temp' = ANY (coalesce(p.proconfig, '{}'))));

SELECT 'G effective EXECUTE on summary functions' AS section, p.oid::regprocedure::text,
       r.rolname, has_function_privilege(r.oid, p.oid, 'EXECUTE') AS can_execute
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN pg_catalog.pg_roles r
WHERE n.nspname = 'summary' AND r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
ORDER BY 2, 3;

SELECT 'G summary functions executable by PUBLIC (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
WHERE n.nspname = 'summary' AND a.grantee = 0 AND a.privilege_type = 'EXECUTE';

SELECT 'G summary EXECUTE grantees other than login and owner (must be 0)' AS section,
       count(*) AS rows
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
WHERE n.nspname = 'summary' AND a.privilege_type = 'EXECUTE'
  AND a.grantee NOT IN (p.proowner, 'sdr_summary_login'::regrole::oid);

-- H. Inventory, not a check: other SECURITY DEFINER functions outside the
-- system schemas that PUBLIC can execute. Owner review only; this design
-- changes none of them.
SELECT 'H other security definer functions executable by PUBLIC' AS section,
       p.oid::regprocedure::text, pg_catalog.pg_get_userbyid(p.proowner) AS owner
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
WHERE p.prosecdef AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
  AND n.nspname <> 'summary' AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
ORDER BY 2;

-- I. Default privileges that would apply to new objects.
SELECT 'I default acl' AS section, pg_catalog.pg_get_userbyid(d.defaclrole) AS for_role,
       coalesce(n.nspname, '(all)') AS schema, d.defaclobjtype AS objtype,
       d.defaclacl::text AS defaclacl
FROM pg_catalog.pg_default_acl d
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
ORDER BY 2, 3, 4;

-- J. Large objects: PUBLIC and the login must hold no rights.
SELECT 'J large objects' AS section, count(*) AS rows,
       count(*) FILTER (WHERE m.lomacl IS NOT NULL) AS with_explicit_acl
FROM pg_catalog.pg_largeobject_metadata m;

SELECT 'J large objects readable by login (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_largeobject_metadata m
WHERE has_largeobject_privilege('sdr_summary_login', m.oid, 'SELECT')
   OR has_largeobject_privilege('sdr_summary_login', m.oid, 'UPDATE');

-- Any role can create large objects (no privilege governs it), so the
-- login could store data this way; this detects it after the fact.
SELECT 'J large objects owned by either role (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_largeobject_metadata m
WHERE pg_catalog.pg_get_userbyid(m.lomowner) IN ('sdr_summary_login', 'sdr_summary_definer');

SELECT 'J lo_compat_privileges (must be off)' AS section,
       current_setting('lo_compat_privileges') AS setting;

-- K. Unreviewed server-file and admin functions the login could execute.
SELECT 'K server-file and admin functions executable by login (must be 0)' AS section,
       count(*) AS rows
FROM pg_catalog.pg_proc p
WHERE p.pronamespace = 'pg_catalog'::regnamespace
  AND p.proname IN ('pg_read_file', 'pg_read_binary_file', 'pg_ls_dir', 'pg_stat_file',
                    'lo_import', 'lo_export', 'pg_reload_conf', 'pg_rotate_logfile', 'pg_ls_logdir', 'pg_ls_waldir',
                    'pg_ls_tmpdir', 'pg_ls_archive_statusdir', 'dblink_connect')
  AND has_function_privilege('sdr_summary_login', p.oid, 'EXECUTE');

-- Inventory: PUBLIC by default, but each acts only on backends of the
-- caller's own role unless it holds pg_signal_backend.
SELECT 'K backend-signal functions executable by login (own sessions only)' AS section,
       p.oid::regprocedure::text
FROM pg_catalog.pg_proc p
WHERE p.pronamespace = 'pg_catalog'::regnamespace
  AND p.proname IN ('pg_cancel_backend', 'pg_terminate_backend')
  AND has_function_privilege('sdr_summary_login', p.oid, 'EXECUTE')
ORDER BY 2;

SELECT 'K predefined-role memberships of login (must be 0)' AS section, count(*) AS rows
FROM pg_catalog.pg_roles g
WHERE g.rolname LIKE 'pg\_%' AND pg_has_role('sdr_summary_login', g.oid, 'USAGE');

-- L. Extensions present (dblink or postgres_fdw would widen the surface).
SELECT 'L extensions' AS section, e.extname, e.extversion
FROM pg_catalog.pg_extension e ORDER BY 2;

COMMIT;
\echo END-OF-SUMMARY-ATTEST

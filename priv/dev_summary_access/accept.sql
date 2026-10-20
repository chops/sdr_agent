-- ADR-0016 / D-173 installed-state acceptance: the shared-hardening and
-- pg_hba part. Owner-run through accept.sh (which also runs attest.sql and
-- the live pg_hba connection checks); never on its own as acceptance.
-- Read-only: one REPEATABLE READ, READ ONLY transaction over catalogs, the
-- pg_hba file view and the file's modification time. It never reads a table
-- row and changes nothing.
--
-- Every line it prints is "ACCEPT <n> <fixed label> (must be <expected>)|
-- <count or fixed value>|ok" or "...|STOP". Acceptance needs no STOP line and
-- the last line ACCEPT-SQL PASS; otherwise it prints ACCEPT-SQL STOP, rolls
-- back and exits 3.

\set ON_ERROR_STOP on
\pset footer off
-- The same reviewed set as revoke-public-temp-lo.sql.
\set lo_fns 'lo_close(integer);lo_creat(integer);lo_create(oid);lo_from_bytea(oid,bytea);' 'lo_get(oid);lo_get(oid,bigint,integer);lo_lseek(integer,integer,integer);' 'lo_lseek64(integer,bigint,integer);lo_open(oid,integer);lo_put(oid,bigint,bytea);' 'lo_tell(integer);lo_tell64(integer);lo_truncate(integer,integer);' 'lo_truncate64(integer,bigint);lo_unlink(oid);loread(integer,integer);' 'lowrite(integer,bytea)'
-- Server-side large-object functions that are superuser-only by default.
\set lo_su_fns 'lo_export(oid,text);lo_import(text);lo_import(text,oid)'

SELECT current_database() = 'sdr_agent_dev' AS right_db,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) AS is_super \gset
\if :right_db
\else
  \echo ACCEPT-SQL STOP: connect to sdr_agent_dev.
  DO $r$ BEGIN RAISE EXCEPTION 'summary acceptance refused: wrong database'; END $r$;
\endif
\if :is_super
\else
  \echo ACCEPT-SQL STOP: run as a superuser.
  DO $r$ BEGIN RAISE EXCEPTION 'summary acceptance refused: not a superuser'; END $r$;
\endif

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog, pg_temp;

WITH
roles AS (
  SELECT r.oid, r.rolname FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
),
-- Each summary role and every role whose privileges it could use.
reach AS (
  SELECT r.rolname AS principal, g.oid AS via
  FROM roles r JOIN pg_catalog.pg_roles g ON pg_has_role(r.oid, g.oid, 'MEMBER')
),
lo_all AS (
  SELECT p.oid, p.oid::regprocedure::text AS sig
  FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_language l ON l.oid = p.prolang
  WHERE l.lanname = 'internal' AND p.prosrc LIKE 'be\_lo%'
),
exp_hba(rule_number, rule) AS (VALUES
    (1, 'host|{sdr_agent_dev}|{sdr_summary_login}|127.0.0.1|255.255.255.255|trust|'),
    (2, 'host|{all}|{sdr_summary_login}|127.0.0.1|255.255.255.255|reject|'),
    (3, 'host|{replication}|{sdr_summary_login}|127.0.0.1|255.255.255.255|reject|'),
    (4, 'host|{all}|{sdr_summary_login}|::1|ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff|reject|'),
    (5, 'host|{replication}|{sdr_summary_login}|::1|ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff|reject|'),
    (6, 'local|{all}|{sdr_summary_login}|||reject|'),
    (7, 'local|{replication}|{sdr_summary_login}|||reject|')
),
act_hba AS (
  SELECT h.rule_number,
         concat_ws('|', h.type, h.database::text, h.user_name::text, coalesce(h.address, ''),
                   coalesce(h.netmask, ''), h.auth_method, coalesce(h.options::text, '')) AS rule
  FROM pg_catalog.pg_hba_file_rules h
  WHERE h.rule_number BETWEEN 1 AND 7 AND h.error IS NULL
    AND h.file_name = current_setting('hba_file')
),
c(ord, name, expected, actual) AS (
  SELECT 2, 'server version is the reviewed PostgreSQL 18.6', '18.6', current_setting('server_version')
  UNION ALL
  SELECT 3, 'summary roles present', '2', (SELECT count(*)::text FROM roles)
  UNION ALL
  -- The functiondef hashes depend on server formatting; these are the
  -- reviewed PostgreSQL 18.6 values (ADR-0016). attest.sql pins prosrc.
  SELECT 4, 'summary function definitions equal the reviewed PostgreSQL 18.6 functiondef SHA-256', '2',
         (SELECT count(*)::text FROM pg_catalog.pg_proc p
          WHERE p.pronamespace = to_regnamespace('summary')
            AND (p.oid::regprocedure::text, encode(sha256(convert_to(pg_catalog.pg_get_functiondef(p.oid), 'UTF8')), 'hex'))
                IN (('summary.g3_inventory_v1()', 'eae28c02a08eeb532c49d0c0a05b783b4856a1cbbec8c3dfa7706f8b312b829f'),
                    ('summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])',
                     'ea809c263d976e99d5ed7dfa0bfca796b89493704c87f0143c2783c792c2775e')))
  UNION ALL
  SELECT 5, 'TEMP held by PUBLIC on sdr_agent_dev', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_database d,
                 aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
          WHERE d.datname = current_database() AND a.grantee = 0 AND a.privilege_type = 'TEMPORARY')
  UNION ALL
  SELECT 6, 'summary roles that can create temporary objects in sdr_agent_dev (any route)', '0',
         (SELECT count(DISTINCT principal)::text FROM reach
          WHERE has_database_privilege(via, current_database(), 'TEMP'))
  UNION ALL
  SELECT 7, 'reviewed large-object functions present', '17',
         (SELECT count(*)::text FROM lo_all WHERE sig = ANY (string_to_array(:'lo_fns', ';')))
  UNION ALL
  SELECT 8, 'server-side large-object functions not on the reviewed lists', '0',
         (SELECT count(*)::text FROM lo_all
          WHERE NOT sig = ANY (string_to_array(:'lo_fns', ';') || string_to_array(:'lo_su_fns', ';')))
  UNION ALL
  SELECT 9, 'server-side large-object functions executable by PUBLIC', '0',
         (SELECT count(*)::text FROM lo_all WHERE has_function_privilege('public', oid, 'EXECUTE'))
  UNION ALL
  SELECT 10, 'server-side large-object functions executable by either summary role (any route)', '0',
         (SELECT count(*)::text FROM reach CROSS JOIN lo_all
          WHERE has_function_privilege(reach.via, lo_all.oid, 'EXECUTE'))
  UNION ALL
  SELECT 11, 'lo_compat_privileges', 'off', current_setting('lo_compat_privileges')
  UNION ALL
  SELECT 12, 'pg_hba rules with errors', '0',
         (SELECT count(*)::text FROM pg_catalog.pg_hba_file_rules WHERE error IS NOT NULL)
  UNION ALL
  SELECT 13, 'reviewed summary-login rules are pg_hba rules 1 to 7, in order', '7',
         (SELECT count(*)::text FROM act_hba JOIN exp_hba USING (rule_number, rule))
  UNION ALL
  SELECT 14, 'pg_hba.conf loaded after its last change', 'true',
         (pg_catalog.pg_conf_load_time()
            >= (pg_catalog.pg_stat_file(current_setting('hba_file'))).modification)::text
)
SELECT string_agg(format('ACCEPT %s %s (must be %s)|%s|%s', ord, name, expected, coalesce(actual, '(null)'),
                         CASE WHEN actual IS DISTINCT FROM expected THEN 'STOP' ELSE 'ok' END),
                  E'\n' ORDER BY ord) AS accept_report,
       count(*) FILTER (WHERE actual IS DISTINCT FROM expected) = 0 AS accept_ok
FROM c \gset

\echo :accept_report
\if :accept_ok
  COMMIT;
  \echo ACCEPT-SQL PASS
\else
  \echo ACCEPT-SQL STOP
  ROLLBACK;
  DO $r$ BEGIN RAISE EXCEPTION 'summary acceptance refused'; END $r$;
\endif

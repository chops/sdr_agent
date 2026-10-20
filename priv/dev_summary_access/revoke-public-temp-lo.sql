-- ADR-0016 / D-173 choices (1) and (2): a REVIEWED, REQUIRED step of the
-- owner path (OWNER-STEPS.md), not an option. On sdr_agent_dev only, it
-- revokes from PUBLIC:
--   * TEMP on the database; and
--   * EXECUTE on the 17 server-side large-object functions that PUBLIC holds
--     by default on PostgreSQL 18 (the internal `be_lo*` functions listed in
--     :lo_fns below). lo_import and lo_export are already superuser-only by
--     default and are not touched.
-- Both are shared changes to PUBLIC defaults in this database. Their effect
-- on every other role is listed in ADR-0016 ("Shared hardening") for Codex
-- review, and the effect rows below print it for the live cluster.
-- install.sql does not do this; accept.sh STOPs until it is applied.
--
-- Owner-run, as a superuser, connected to sdr_agent_dev:
--   psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
--     -v mode=inventory -f priv/dev_summary_access/revoke-public-temp-lo.sql
--   mode=inventory  read-only; changes nothing. Review the effect rows.
--   mode=apply      one transaction. Refuses (exit 3, nothing changed) unless
--                   PUBLIC holds TEMP here and the catalog's PUBLIC-executable
--                   large-object functions are exactly the reviewed 17; after
--                   the revokes it re-checks inside the transaction.
--   mode=restore    rollback, only after uninstall.sql: refuses while either
--                   summary role exists. Re-grants exactly those PUBLIC
--                   entries (TEMP, and EXECUTE on the 17), restoring the
--                   PostgreSQL default effective privileges.
-- Every refusal exits 3 and prints no END marker.

\set ON_ERROR_STOP on
\pset footer off
-- The reviewed set, read from the PostgreSQL 18.6 catalog (ADR-0016 records
-- the query and its result): every internal be_lo* function in pg_catalog
-- that PUBLIC can execute by default.
\set lo_fns 'lo_close(integer);lo_creat(integer);lo_create(oid);lo_from_bytea(oid,bytea);' 'lo_get(oid);lo_get(oid,bigint,integer);lo_lseek(integer,integer,integer);' 'lo_lseek64(integer,bigint,integer);lo_open(oid,integer);lo_put(oid,bigint,bytea);' 'lo_tell(integer);lo_tell64(integer);lo_truncate(integer,integer);' 'lo_truncate64(integer,bigint);lo_unlink(oid);loread(integer,integer);' 'lowrite(integer,bytea)'

\if :{?mode}
\else
  \echo REFUSED: pass -v mode=inventory, mode=apply or mode=restore. Nothing was changed.
  DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: no mode'; END $r$;
\endif
SELECT current_database() = 'sdr_agent_dev' AS db_ok,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) AS su_ok,
       :'mode' IN ('inventory', 'apply', 'restore') AS mode_ok,
       :'mode' = 'inventory' AS is_inventory,
       :'mode' = 'apply' AS is_apply \gset
\if :db_ok
\else
  \echo REFUSED: run against sdr_agent_dev only. Nothing was changed.
  DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: wrong database'; END $r$;
\endif
\if :mode_ok
\else
  \echo REFUSED: mode must be inventory, apply or restore. Nothing was changed.
  DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: bad mode'; END $r$;
\endif
\if :is_inventory
\else
  \if :su_ok
  \else
    \echo REFUSED: apply and restore need a superuser. Nothing was changed.
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: not a superuser'; END $r$;
  \endif
\endif

\if :is_inventory
  BEGIN TRANSACTION READ ONLY;
\else
  BEGIN;
\endif
SET LOCAL search_path = pg_catalog, pg_temp;

-- Effects: every role that can log in here, and the summary definer. A role
-- loses TEMP (or a function) only if it is not a superuser, not the owner,
-- and holds it through no explicit non-PUBLIC grant it can use.
SELECT 'effect' AS section, r.rolname, r.rolsuper,
       has_database_privilege(r.oid, d.oid, 'TEMP') AS temp_now,
       CASE WHEN r.rolsuper OR d.datdba = r.oid THEN false
            WHEN EXISTS (SELECT 1 FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
                         WHERE a.privilege_type = 'TEMPORARY' AND a.grantee <> 0
                           AND pg_has_role(r.oid, a.grantee, 'USAGE')) THEN false
            ELSE has_database_privilege(r.oid, d.oid, 'TEMP') END AS would_lose_temp,
       (SELECT count(*) FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'pg_catalog'::regnamespace
          AND p.oid::regprocedure::text = ANY (string_to_array(:'lo_fns', ';'))
          AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS lo_functions_now,
       (SELECT count(*) FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'pg_catalog'::regnamespace
          AND p.oid::regprocedure::text = ANY (string_to_array(:'lo_fns', ';'))
          AND has_function_privilege(r.oid, p.oid, 'EXECUTE')
          AND NOT r.rolsuper AND p.proowner <> r.oid
          AND NOT EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                          WHERE a.privilege_type = 'EXECUTE' AND a.grantee <> 0
                            AND pg_has_role(r.oid, a.grantee, 'USAGE'))) AS lo_functions_lost
FROM pg_catalog.pg_roles r
CROSS JOIN pg_catalog.pg_database d
WHERE d.datname = current_database()
  AND ((r.rolcanlogin AND has_database_privilege(r.oid, d.oid, 'CONNECT'))
       OR r.rolname = 'sdr_summary_definer')
ORDER BY 2;

SELECT 'current objects' AS section,
       (SELECT count(*) FROM pg_catalog.pg_class c WHERE c.relpersistence = 't') AS temporary_relations,
       (SELECT count(*) FROM pg_catalog.pg_largeobject_metadata) AS large_objects,
       (SELECT count(*) FROM pg_catalog.pg_largeobject_metadata m
        JOIN pg_catalog.pg_roles o ON o.oid = m.lomowner WHERE NOT o.rolsuper) AS large_objects_owned_by_non_superusers;

-- State before: what PUBLIC holds now, and whether the catalog's
-- PUBLIC-executable large-object set is exactly the reviewed one.
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_database d,
                      aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
               WHERE d.datname = current_database() AND a.grantee = 0
                 AND a.privilege_type = 'TEMPORARY') AS public_temp,
       (SELECT count(*) FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'pg_catalog'::regnamespace
          AND p.oid::regprocedure::text = ANY (string_to_array(:'lo_fns', ';'))) AS lo_present,
       (SELECT count(*) FROM pg_catalog.pg_proc p
        WHERE p.pronamespace = 'pg_catalog'::regnamespace
          AND p.oid::regprocedure::text = ANY (string_to_array(:'lo_fns', ';'))
          AND has_function_privilege('public', p.oid, 'EXECUTE')) AS lo_public_reviewed,
       (SELECT count(*) FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_language l ON l.oid = p.prolang
        WHERE l.lanname = 'internal' AND p.prosrc LIKE 'be\_lo%'
          AND has_function_privilege('public', p.oid, 'EXECUTE')) AS lo_public_all,
       EXISTS (SELECT 1 FROM pg_catalog.pg_roles
               WHERE rolname IN ('sdr_summary_login', 'sdr_summary_definer')) AS summary_roles \gset
SELECT 'before' AS section, :'public_temp' AS public_temp, :'lo_present' AS reviewed_lo_functions_present,
       :'lo_public_reviewed' AS reviewed_lo_functions_public, :'lo_public_all' AS all_lo_functions_public;

\if :is_inventory
  COMMIT;
  \echo END-OF-REVOKE-PUBLIC-TEMP-LO-INVENTORY (nothing changed)
\elif :is_apply
  SELECT :'public_temp'::boolean AND :'lo_present' = '17' AND :'lo_public_reviewed' = '17'
         AND :'lo_public_all' = '17' AS pre_ok \gset
  \if :pre_ok
  \else
    \echo REFUSED: PUBLIC does not hold exactly the reviewed TEMP and 17 large-object EXECUTE defaults (already applied, or an unreviewed catalog). Nothing was changed.
    ROLLBACK;
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: precondition'; END $r$;
  \endif
  REVOKE TEMP ON DATABASE sdr_agent_dev FROM PUBLIC;
  REVOKE EXECUTE ON FUNCTION
    pg_catalog.lo_close(integer), pg_catalog.lo_creat(integer), pg_catalog.lo_create(oid),
    pg_catalog.lo_from_bytea(oid, bytea), pg_catalog.lo_get(oid),
    pg_catalog.lo_get(oid, bigint, integer), pg_catalog.lo_lseek(integer, integer, integer),
    pg_catalog.lo_lseek64(integer, bigint, integer), pg_catalog.lo_open(oid, integer),
    pg_catalog.lo_put(oid, bigint, bytea), pg_catalog.lo_tell(integer),
    pg_catalog.lo_tell64(integer), pg_catalog.lo_truncate(integer, integer),
    pg_catalog.lo_truncate64(integer, bigint), pg_catalog.lo_unlink(oid),
    pg_catalog.loread(integer, integer), pg_catalog.lowrite(integer, bytea)
  FROM PUBLIC;
  -- Re-check inside the transaction: PUBLIC holds neither, and no existing
  -- summary role can create temporary objects or call any be_lo* function.
  SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database d,
                            aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
                     WHERE d.datname = current_database() AND a.grantee = 0
                       AND a.privilege_type = 'TEMPORARY')
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                         JOIN pg_catalog.pg_language l ON l.oid = p.prolang
                         WHERE l.lanname = 'internal' AND p.prosrc LIKE 'be\_lo%'
                           AND has_function_privilege('public', p.oid, 'EXECUTE'))
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
                         WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
                           AND (has_database_privilege(r.oid, current_database(), 'TEMP')
                                OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                           JOIN pg_catalog.pg_language l ON l.oid = p.prolang
                                           WHERE l.lanname = 'internal' AND p.prosrc LIKE 'be\_lo%'
                                             AND has_function_privilege(r.oid, p.oid, 'EXECUTE'))))
         AS post_ok \gset
  \if :post_ok
    COMMIT;
    \echo END-OF-REVOKE-PUBLIC-TEMP-LO-APPLIED
  \else
    \echo REFUSED: the revokes did not take full effect. Rolled back; nothing was changed.
    ROLLBACK;
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object revoke refused: post-check'; END $r$;
  \endif
\else
  \if :summary_roles
    \echo REFUSED: run uninstall.sql first; restore never re-opens TEMP or large objects to an installed summary role. Nothing was changed.
    ROLLBACK;
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object restore refused: summary roles exist'; END $r$;
  \endif
  SELECT :'lo_present' = '17' AS pre_ok \gset
  \if :pre_ok
  \else
    \echo REFUSED: the reviewed 17 large-object functions are not all present. Nothing was changed.
    ROLLBACK;
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object restore refused: precondition'; END $r$;
  \endif
  GRANT TEMP ON DATABASE sdr_agent_dev TO PUBLIC;
  GRANT EXECUTE ON FUNCTION
    pg_catalog.lo_close(integer), pg_catalog.lo_creat(integer), pg_catalog.lo_create(oid),
    pg_catalog.lo_from_bytea(oid, bytea), pg_catalog.lo_get(oid),
    pg_catalog.lo_get(oid, bigint, integer), pg_catalog.lo_lseek(integer, integer, integer),
    pg_catalog.lo_lseek64(integer, bigint, integer), pg_catalog.lo_open(oid, integer),
    pg_catalog.lo_put(oid, bigint, bytea), pg_catalog.lo_tell(integer),
    pg_catalog.lo_tell64(integer), pg_catalog.lo_truncate(integer, integer),
    pg_catalog.lo_truncate64(integer, bigint), pg_catalog.lo_unlink(oid),
    pg_catalog.loread(integer, integer), pg_catalog.lowrite(integer, bytea)
  TO PUBLIC;
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_database d,
                        aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
                 WHERE d.datname = current_database() AND a.grantee = 0
                   AND a.privilege_type = 'TEMPORARY')
         AND (SELECT count(*) FROM pg_catalog.pg_proc p
              WHERE p.pronamespace = 'pg_catalog'::regnamespace
                AND p.oid::regprocedure::text = ANY (string_to_array(:'lo_fns', ';'))
                AND has_function_privilege('public', p.oid, 'EXECUTE')) = 17 AS post_ok \gset
  \if :post_ok
    COMMIT;
    \echo END-OF-REVOKE-PUBLIC-TEMP-LO-RESTORED
  \else
    \echo REFUSED: the restore did not take full effect. Rolled back; nothing was changed.
    ROLLBACK;
    DO $r$ BEGIN RAISE EXCEPTION 'TEMP/large-object restore refused: post-check'; END $r$;
  \endif
\endif

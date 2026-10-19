-- ADR-0016 OPTIONAL, separate owner decision: revoke TEMP on sdr_agent_dev
-- from PUBLIC. install.sql does not do this, because it is a database-wide
-- change to a shared PUBLIC default (Codex D-168 requirement 3), not part of
-- the summary role. Without it the login can create temporary tables (its
-- own session only; it cannot read or shadow anything the functions use).
--
-- Step 1 (read-only, run first and review): psql -X -q -v ON_ERROR_STOP=1
--   -d sdr_agent_dev -v mode=inventory -f optional-revoke-temp.sql
-- Step 2 (only after the owner approves the inventory):
--   ... -v mode=apply -f optional-revoke-temp.sql
-- Undo: GRANT TEMP ON DATABASE sdr_agent_dev TO PUBLIC;

\set ON_ERROR_STOP on
\pset footer off
\if :{?mode}
\else
  \echo REFUSED: pass -v mode=inventory or -v mode=apply. Nothing was changed.
  \quit
\endif
SELECT current_database() = 'sdr_agent_dev' AS db_ok,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) AS su_ok,
       :'mode' IN ('inventory', 'apply') AS mode_ok,
       :'mode' = 'apply' AS is_apply \gset
\if :db_ok
\else
  \echo REFUSED: run against sdr_agent_dev only. Nothing was changed.
  \quit
\endif
\if :mode_ok
\else
  \echo REFUSED: mode must be inventory or apply. Nothing was changed.
  \quit
\endif

-- Effects inventory: every login role that can connect here, whether it
-- would lose TEMP (non-superuser, no direct or inherited explicit grant),
-- and its current temporary relations.
SELECT 'effect' AS section, r.rolname, r.rolsuper,
       has_database_privilege(r.oid, d.oid, 'TEMP') AS temp_now,
       CASE WHEN r.rolsuper THEN false
            WHEN EXISTS (SELECT 1 FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
                         WHERE a.privilege_type = 'TEMPORARY' AND a.grantee <> 0
                           AND pg_has_role(r.oid, a.grantee, 'USAGE')) THEN false
            WHEN d.datdba = r.oid THEN false
            ELSE has_database_privilege(r.oid, d.oid, 'TEMP') END AS would_lose_temp
FROM pg_catalog.pg_roles r
CROSS JOIN pg_catalog.pg_database d
WHERE d.datname = current_database() AND r.rolcanlogin
  AND has_database_privilege(r.oid, d.oid, 'CONNECT')
ORDER BY 2;

SELECT 'current temporary relations' AS section, count(*) AS rows
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relpersistence = 't';

SELECT 'database acl before' AS section, datacl::text FROM pg_catalog.pg_database
WHERE datname = current_database();

\if :is_apply
  \if :su_ok
  \else
    \echo REFUSED: apply needs a superuser. Nothing was changed.
    \quit
  \endif
  BEGIN;
  REVOKE TEMP ON DATABASE sdr_agent_dev FROM PUBLIC;
  SELECT 'database acl after' AS section, datacl::text FROM pg_catalog.pg_database
  WHERE datname = current_database();
  SELECT 'login TEMP after (must be f)' AS section,
         has_database_privilege('sdr_summary_login', current_database(), 'TEMP') AS can_temp;
  COMMIT;
  \echo END-OF-OPTIONAL-REVOKE-TEMP-APPLIED
\else
  \echo END-OF-OPTIONAL-REVOKE-TEMP-INVENTORY (nothing changed)
\endif

-- D-168 dev-database summary access: uninstall (ADR-0016). Owner-run only,
-- as a superuser, connected to sdr_agent_dev. One transaction. It removes
-- exactly what install.sql created and nothing else; it refuses if either
-- role owns anything beyond the two reviewed functions, or holds a
-- privilege in another database (DROP OWNED acts on this database only).
-- It does not undo optional-revoke-temp.sql.

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
  \echo REFUSED: uninstall needs a superuser. Nothing was changed.
  \quit
\endif

BEGIN;

DO $guard$
DECLARE v_other bigint;
BEGIN
  SELECT count(*) INTO v_other
  FROM (SELECT p.oid::regprocedure::text AS o, p.proowner AS w FROM pg_catalog.pg_proc p
        UNION ALL SELECT c.oid::regclass::text, c.relowner FROM pg_catalog.pg_class c
        UNION ALL SELECT n.nspname::text, n.nspowner FROM pg_catalog.pg_namespace n
        UNION ALL SELECT t.oid::regtype::text, t.typowner FROM pg_catalog.pg_type t) x
  WHERE pg_catalog.pg_get_userbyid(x.w) IN ('sdr_summary_login', 'sdr_summary_definer')
    AND x.o NOT IN ('summary.g3_inventory_v1()',
                    'summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])');
  IF v_other > 0 THEN
    RAISE EXCEPTION 'REFUSED: a summary role owns an unreviewed object; nothing was changed';
  END IF;
  SELECT count(*) INTO v_other
  FROM pg_catalog.pg_shdepend s
  JOIN pg_catalog.pg_roles r ON r.oid = s.refobjid AND s.refclassid = 'pg_authid'::regclass
  WHERE r.rolname IN ('sdr_summary_login', 'sdr_summary_definer')
    AND s.dbid NOT IN (0, (SELECT oid FROM pg_catalog.pg_database
                           WHERE datname = current_database()));
  IF v_other > 0 THEN
    RAISE EXCEPTION 'REFUSED: a summary role has a dependency in another database; nothing was changed';
  END IF;
END
$guard$;

DROP FUNCTION summary.g3_inventory_v1();
DROP FUNCTION summary.gdemo_drain_v1(text, timestamptz, integer, text[]);
DROP SCHEMA summary;
-- Revokes the remaining grants (CONNECT, schema USAGE, column SELECT) and
-- the definer's default-privilege entry, in this database.
DROP OWNED BY sdr_summary_login, sdr_summary_definer;
DROP ROLE sdr_summary_login;
DROP ROLE sdr_summary_definer;

COMMIT;
\echo END-OF-SUMMARY-UNINSTALL

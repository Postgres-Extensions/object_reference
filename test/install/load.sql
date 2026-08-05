/*
 * Single, committed-once installer for the test suite's dependency: the
 * object_reference extension.
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite. Because its state is
 * committed it persists into every test and runs ONCE instead of per-test
 * (pgTAP rolls back each test/sql/ file -- see test/load.sql -- so tests read
 * the extension's objects but never modify them here).
 *
 * Three modes, selected by the object_reference.test_load_mode placeholder
 * GUC, which the Makefile's TEST_LOAD_SOURCE block sets via PGOPTIONS (fresh
 * is the default):
 *   - fresh (default): plain CREATE EXTENSION object_reference (current
 *     version), CASCADE (object_reference requires cat_tools).
 *   - update: CREATE EXTENSION at an older version
 *     (object_reference.test_update_from, default 0.1.0 -- the only real
 *     historical PGXN release) then ALTER EXTENSION UPDATE -- to
 *     object_reference.test_update_to when that GUC is non-empty, otherwise
 *     to the current default_version ("stable"). Reusing the SAME suite and
 *     expected output asserts an updated database behaves identically to a
 *     fresh install.
 *   - existing: the extension is ALREADY installed (by binary pg_upgrade, or
 *     an ALTER EXTENSION UPDATE performed outside the suite). load.sql must
 *     NOT drop/create/update it -- that would destroy exactly what the suite
 *     validates. It only asserts presence + current version.
 *
 * test/load.sql (run per-test, rolled back) installs nothing itself; its
 * `CREATE EXTENSION IF NOT EXISTS` is a no-op here since the extension is
 * already installed by this file, and only does real work for
 * test/dump/load_all.sql's standalone flow, which never goes through
 * test/install at all.
 *
 * ON_ERROR_STOP: this file runs standalone (not \i'd via
 * test/pgxntool/psql.sql, which would normally set it), and pg_regress
 * doesn't set it either -- without it, an unexpected error here (e.g. a
 * missing dependency the CASCADE doesn't cover) doesn't abort the script; it
 * just prints the error and keeps going statement by statement, potentially
 * leaving the extension half-installed while later steps run against that
 * broken state and the run-log genuinely does show the failure, just buried
 * many statements deep instead of stopping at the first one.
 */
\set ON_ERROR_STOP 1

SET client_min_messages = WARNING;

/*
 * Mode selection. The Makefile always exports object_reference.test_load_mode
 * via PGOPTIONS. Read it WITHOUT missing_ok: if the GUC did not propagate (a
 * break anywhere in make -> PGOPTIONS -> env -> psql), current_setting errors
 * here and the whole install step fails loudly, instead of silently falling
 * back to a default and running the wrong suite. The DO block then rejects
 * any value other than fresh/update/existing with a clear message.
 */
SELECT current_setting('object_reference.test_load_mode') AS object_reference_test_load_mode
\gset

DO $DO$
BEGIN
  IF current_setting('object_reference.test_load_mode') NOT IN ('fresh', 'update', 'existing') THEN
    RAISE EXCEPTION
      'object_reference.test_load_mode must be ''fresh'', ''update'' or ''existing'', got ''%'''
      , current_setting('object_reference.test_load_mode')
    ;
  END IF;
END
$DO$;

SELECT
    :'object_reference_test_load_mode' = 'update'   AS object_reference_mode_update
  , :'object_reference_test_load_mode' = 'existing' AS object_reference_mode_existing
\gset

\if :object_reference_mode_existing
/*
 * existing mode: do NOT touch the extension. Assert it is installed and at
 * the current default_version -- the pg_upgrade / external update the
 * database just went through is exactly what the suite is validating, so
 * dropping or reinstalling it would defeat the test. Fail loudly on absence
 * or mismatch.
 *
 * A future CI-wiring PR (this PR only builds the local machinery -- see the
 * containing PR's description) should additionally plant a dependency guard
 * here: a view typed on a stable, object_reference-owned member (so a
 * non-CASCADE DROP EXTENSION fails) and prove that non-CASCADE drop actually
 * fails, so a stray CASCADE drop or logic bug that falls through to the
 * fresh/update branch is caught rather than silently retesting a fresh
 * install. The anchor to use for that guard is _object_reference.object's row
 * type (composite type of the extension's core object-tracking table): it is
 * object_reference-owned (unlike cat_tools.object_type, which this extension
 * only consumes), and no update script -- including 0.1.0--stable.sql -- ever
 * drops or redefines that table.
 */
DO $DO$
DECLARE
  v_installed text := (SELECT extversion FROM pg_extension WHERE extname = 'object_reference');
  v_default   text := (SELECT default_version FROM pg_available_extensions WHERE name = 'object_reference');
BEGIN
  IF v_installed IS NULL THEN
    RAISE EXCEPTION 'test_load_mode=existing but object_reference is not installed';
  END IF;
  IF v_installed IS DISTINCT FROM v_default THEN
    RAISE EXCEPTION
      'object_reference is installed at version % but the current default_version is %'
      , v_installed, v_default
    ;
  END IF;
END
$DO$;
\else
/*
 * fresh / update: (re)install from scratch. Drop-first so a re-run on a
 * persistent cluster installs the newest build instead of reusing stale
 * objects.
 *
 * DROP EXTENSION does not remove object_reference__usage /
 * object_reference__dependency: the extension's own install script creates
 * them with a duplicate_object-tolerant CREATE ROLE, and roles are global
 * objects, not extension members, so they survive DROP EXTENSION. That
 * duplicate_object handling makes plain re-creation safe, but it does NOT
 * clear any grants a previous test run (or a previous, differently-shaped
 * version of this extension) may have left on the role -- e.g. the
 * schema_privs_are()/table_privs_are() checks in test/sql/base.sql assert an
 * EXACT privilege set, which a stale extra grant from an earlier run on the
 * same persistent cluster would silently break. Drop both roles explicitly
 * via pg_temp.drop_role(): DROP OWNED BY first strips any privileges granted
 * TO the role so DROP ROLE cannot fail with a dependency error, and the
 * pg_roles guard skips a not-yet-existing role (DROP OWNED BY errors on one).
 */
DROP EXTENSION IF EXISTS object_reference CASCADE;

CREATE FUNCTION pg_temp.drop_role(
  role_name text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('DROP OWNED BY %I', role_name);
    EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
  END IF;
END
$$;

SELECT pg_temp.drop_role('object_reference__usage');
SELECT pg_temp.drop_role('object_reference__dependency');

\if :object_reference_mode_update
/*
 * update mode: install an older version, then ALTER EXTENSION UPDATE. The
 * from/to versions come from the Makefile (TEST_UPDATE_FROM / TEST_UPDATE_TO,
 * exported as GUCs). An empty test_update_to means "update to the current
 * default_version" (the widest path); a non-empty value targets a specific
 * version.
 */
SELECT current_setting('object_reference.test_update_from') AS object_reference_test_update_from \gset
SELECT current_setting('object_reference.test_update_to')   AS object_reference_test_update_to   \gset
/*
 * Build the optional target clause once so a SINGLE ALTER EXTENSION covers
 * both cases: an empty test_update_to yields '' (update to the current
 * default_version -- the widest path); a non-empty value yields "TO '<v>'".
 * format(%L) quotes the version literal safely; the bare :clause
 * interpolation below then drops it in verbatim.
 */
SELECT CASE WHEN :'object_reference_test_update_to' = '' THEN ''
            ELSE format('TO %L', :'object_reference_test_update_to') END
  AS object_reference_update_to_clause \gset

/*
 * 0.1.0 (the default test_update_from floor)'s own install script creates a
 * trigger that calls count_nulls' not_null_count_trigger() -- a dependency
 * object_reference.control no longer declares in `requires` now that the
 * reg* pseudotype removal made it unnecessary, so CASCADE below will NOT
 * bring count_nulls in automatically the way it would have when 0.1.0 was
 * current. Install it explicitly first; the Makefile's conditional `install:
 * count_nulls` prerequisite (TEST_LOAD_SOURCE=update only) ensures it's
 * actually present on disk to install from.
 */
CREATE EXTENSION IF NOT EXISTS count_nulls;

CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;
/*
 * Suppress the deprecation NOTICEs the update script emits (e.g. the reg*
 * pseudotype removal), matching cat_tools' own install/load.sql.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SET client_min_messages = WARNING;
\else
CREATE EXTENSION object_reference CASCADE;
\endif
-- end \if :object_reference_mode_update (fresh vs. update install branch)
\endif
-- end \if :object_reference_mode_existing (existing mode skips the whole (re)install block)

-- vi: expandtab sw=2 ts=2

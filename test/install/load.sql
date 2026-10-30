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

/*
 * Update scenarios. Each installs the old version inside its own
 * transaction and rolls back, so nothing leaks into the committed install
 * below; that includes sequence values, which a rollback alone would not
 * reset on an install committed beforehand. Each one starts a capture group,
 * asserts the event trigger state it starts the update from, updates, and
 * checks the result:
 *   1. All three triggers at their default ENABLE; a table created after the
 *      update is captured.
 *   2. zzz__object_reference_drop already disabled, and still disabled after.
 *   3. A table captured before the update is renamed after it; the capture
 *      group shows the new name.
 */
CREATE FUNCTION pg_temp.assert_event_trigger_state(
  step text
  , capture_state "char"
  , fix_identity_state "char"
  , drop_state "char"
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_mismatches text;
BEGIN
  SELECT string_agg(
        format('%I is %L, expected %L.', e.evtname, t.evtenabled, e.evtenabled)
        , ' ' ORDER BY e.evtname
      )
    INTO v_mismatches
    FROM (VALUES
        ('zzz_object_reference_capture'::name, capture_state)
      , ('zzz_object_reference__fix_identity', fix_identity_state)
      , ('zzz__object_reference_drop', drop_state)
    ) e(evtname, evtenabled)
    LEFT JOIN pg_catalog.pg_event_trigger t USING (evtname)
    WHERE t.evtenabled IS DISTINCT FROM e.evtenabled
  ;
  IF v_mismatches IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected event trigger state %', step
      USING DETAIL = v_mismatches
    ;
  END IF;
END
$$;

CREATE FUNCTION pg_temp.assert_update_finished(
  step text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_installed text := (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'object_reference');
  v_target    text := coalesce(
    nullif(current_setting('object_reference.test_update_to'), '')
    , (SELECT default_version FROM pg_catalog.pg_available_extensions WHERE name = 'object_reference')
  );
BEGIN
  IF v_installed IS DISTINCT FROM v_target THEN
    RAISE EXCEPTION 'object_reference is at version % %, expected %', v_installed, step, v_target;
  END IF;
  IF to_regclass('pg_temp.__object_reference__event_trigger_state') IS NOT NULL
    OR to_regclass('pg_temp.__object_reference__bootstrap_event_trigger_state') IS NOT NULL
  THEN
    RAISE EXCEPTION 'event trigger state table left behind %', step;
  END IF;
END
$$;

CREATE FUNCTION pg_temp.assert_capture_group(
  step text
  , expected text[]
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_members text[];
BEGIN
  SELECT coalesce(array_agg(array_to_string(o.object_names, '.') ORDER BY o.object_names), '{}')
    INTO v_members
    FROM _object_reference.object_group__object m
      JOIN _object_reference.object o USING (object_id)
    WHERE m.object_group_id = (object_reference.object_group__get('load_update_scenario')).object_group_id
  ;
  IF v_members IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'unexpected capture group members %', step
      USING DETAIL = format('Members are %L, expected %L.', v_members, expected)
    ;
  END IF;
END
$$;

SET client_min_messages = ERROR;

BEGIN;
CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;
SELECT object_reference.capture__start(object_reference.object_group__create('load_update_scenario'));
SELECT pg_temp.assert_event_trigger_state('before the update in scenario 1', 'O', 'O', 'O');
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SELECT pg_temp.assert_update_finished('after the update in scenario 1');
SELECT pg_temp.assert_event_trigger_state('after the update in scenario 1', 'O', 'O', 'O');
SELECT pg_temp.assert_capture_group('after the update in scenario 1', '{}');
CREATE TABLE load_update_scenario__after();
SELECT pg_temp.assert_capture_group('after CREATE TABLE in scenario 1', '{public.load_update_scenario__after}');
ROLLBACK;

BEGIN;
CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;
ALTER EVENT TRIGGER zzz__object_reference_drop DISABLE;
SELECT object_reference.capture__start(object_reference.object_group__create('load_update_scenario'));
SELECT pg_temp.assert_event_trigger_state('before the update in scenario 2', 'O', 'O', 'D');
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SELECT pg_temp.assert_update_finished('after the update in scenario 2');
SELECT pg_temp.assert_event_trigger_state('after the update in scenario 2', 'O', 'O', 'D');
SELECT pg_temp.assert_capture_group('after the update in scenario 2', '{}');
ROLLBACK;

BEGIN;
CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;
SELECT object_reference.capture__start(object_reference.object_group__create('load_update_scenario'));
CREATE TABLE load_update_scenario__before();
SELECT pg_temp.assert_capture_group('before the update in scenario 3', '{public.load_update_scenario__before}');
SELECT pg_temp.assert_event_trigger_state('before the update in scenario 3', 'O', 'O', 'O');
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SELECT pg_temp.assert_update_finished('after the update in scenario 3');
SELECT pg_temp.assert_event_trigger_state('after the update in scenario 3', 'O', 'O', 'O');
ALTER TABLE load_update_scenario__before RENAME TO load_update_scenario__renamed;
SELECT pg_temp.assert_capture_group('after the rename in scenario 3', '{public.load_update_scenario__renamed}');
ROLLBACK;

SET client_min_messages = WARNING;

CREATE EXTENSION object_reference VERSION :'object_reference_test_update_from' CASCADE;

/*
 * Fail unless the update restores each of the extension's event triggers to
 * the exact state it had before, starting each from a distinct non-default
 * state. A failed check exits psql nonzero (ON_ERROR_STOP), but that does not
 * fail the make run on any PostgreSQL version: pg_regress 16+ prints
 * "not ok" and PG12's prints "ok", and make exits 0 either way. This
 * file's own output is never compared against anything. All three are reset
 * to ENABLE afterwards, so the rest of the suite runs as usual.
 */
BEGIN;
ALTER EVENT TRIGGER zzz_object_reference_capture DISABLE;
ALTER EVENT TRIGGER zzz_object_reference__fix_identity ENABLE REPLICA;
ALTER EVENT TRIGGER zzz__object_reference_drop ENABLE ALWAYS;

/*
 * Suppress the deprecation NOTICEs the update script emits (e.g. the reg*
 * pseudotype removal), matching cat_tools' own install/load.sql.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION object_reference UPDATE :object_reference_update_to_clause;
SET client_min_messages = WARNING;

DO $DO$
DECLARE
  v_mismatches text;
BEGIN
  SELECT string_agg(
        format('%I is %L, expected %L.', e.evtname, t.evtenabled, e.evtenabled)
        , ' ' ORDER BY e.evtname
      )
    INTO v_mismatches
    FROM (VALUES
        ('zzz_object_reference_capture'::name, 'D'::"char")
      , ('zzz_object_reference__fix_identity', 'R')
      , ('zzz__object_reference_drop', 'A')
    ) e(evtname, evtenabled)
    LEFT JOIN pg_catalog.pg_event_trigger t USING (evtname)
    WHERE t.evtenabled IS DISTINCT FROM e.evtenabled
  ;
  IF v_mismatches IS NOT NULL THEN
    RAISE EXCEPTION 'ALTER EXTENSION UPDATE did not restore event trigger state'
      USING DETAIL = v_mismatches
    ;
  END IF;
END
$DO$;

ALTER EVENT TRIGGER zzz_object_reference_capture ENABLE;
ALTER EVENT TRIGGER zzz_object_reference__fix_identity ENABLE;
ALTER EVENT TRIGGER zzz__object_reference_drop ENABLE;
COMMIT;
\else
CREATE EXTENSION object_reference CASCADE;
\endif
-- end \if :object_reference_mode_update (fresh vs. update install branch)
\endif
-- end \if :object_reference_mode_existing (existing mode skips the whole (re)install block)

-- vi: expandtab sw=2 ts=2

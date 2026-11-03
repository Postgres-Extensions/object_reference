\set ECHO none
/*
 * Update-mode scenarios (make test-update): install the old version, then
 * ALTER EXTENSION UPDATE, in rolled-back transactions, so nothing persists.
 * Each starts a capture group, asserts the event trigger state it starts the
 * update from, updates, and checks the result:
 *   1. All three triggers at their default ENABLE; a table created after the
 *      update is captured.
 *   2. zzz__object_reference_drop already disabled, and still disabled after.
 *   3. A table captured before the update is renamed after it; the capture
 *      group shows the new name.
 *
 * Runs only when object_reference.test_load_mode is 'update' (the Makefile's
 * TEST_LOAD_SOURCE); the output is empty in every mode, so a failed assertion
 * shows up as a diff against the expected file, which fails test-build.
 * count_nulls is created per scenario (the 0.1.0 install script needs it) and
 * rolled back with it.
 */
\set ON_ERROR_STOP 1

SELECT current_setting('object_reference.test_load_mode') = 'update' AS object_reference_mode_update
\gset

\if :object_reference_mode_update
\o /dev/null

SELECT current_setting('object_reference.test_update_from') AS object_reference_test_update_from \gset
SELECT CASE WHEN current_setting('object_reference.test_update_to') = '' THEN ''
            ELSE format('TO %L', current_setting('object_reference.test_update_to')) END
  AS object_reference_update_to_clause \gset

SET client_min_messages = ERROR;

\i test/helpers/event_trigger_state.sql

/*
 * 0.1.0's install script sets client_min_messages = WARNING itself and calls a
 * cat_tools function that has since been deprecated, so the session setting
 * can't hide its WARNINGs and they would vary with the cat_tools version. A
 * per-function setting can: create cat_tools (rolled back with the scenario)
 * and silence every function in it.
 */
CREATE FUNCTION pg_temp.quiet_cat_tools() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_function regprocedure;
BEGIN
  CREATE EXTENSION IF NOT EXISTS cat_tools;
  FOR v_function IN
    SELECT p.oid::regprocedure
      FROM pg_catalog.pg_proc p
      WHERE p.pronamespace = 'cat_tools'::regnamespace AND p.prokind = 'f'
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET client_min_messages = error', v_function);
  END LOOP;
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
  IF to_regclass('pg_temp.__object_reference__event_trigger_state') IS NOT NULL THEN
    RAISE EXCEPTION 'event trigger state table left behind %', step;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger WHERE evtname = '__object_reference__event_trigger_sentinel')
    OR to_regprocedure('pg_temp.__object_reference__event_trigger_sentinel()') IS NOT NULL
  THEN
    RAISE EXCEPTION 'sentinel event trigger or its function left behind %', step;
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

BEGIN;
SELECT pg_temp.quiet_cat_tools();
CREATE EXTENSION IF NOT EXISTS count_nulls;
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
SELECT pg_temp.quiet_cat_tools();
CREATE EXTENSION IF NOT EXISTS count_nulls;
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
SELECT pg_temp.quiet_cat_tools();
CREATE EXTENSION IF NOT EXISTS count_nulls;
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

\o
\endif

-- vi: expandtab sw=2 ts=2

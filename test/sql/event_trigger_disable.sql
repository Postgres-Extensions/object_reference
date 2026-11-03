\set ECHO none

\i test/load.sql

/*
 * This file assumes its transaction is never committed (test/load.sql opens
 * it, test/finish.sql leaves it open) and that pg_regress runs the test files
 * one at a time, so no other session ever sees an event trigger disabled here.
 * Most tests use their own no-op event triggers, whose names and prior states
 * they control; the capture test disables the real zzz_object_reference_capture.
 */
CREATE FUNCTION event_trigger_disable_test__noop() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
END
$$;
CREATE EVENT TRIGGER event_trigger_disable_test__a ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();
CREATE EVENT TRIGGER event_trigger_disable_test__b ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();
-- Names whose "C" order (B, a, z) differs from a typical locale order (a, B, z)
CREATE EVENT TRIGGER "event_trigger_disable_test__B" ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();
CREATE EVENT TRIGGER event_trigger_disable_test__z ON ddl_command_start EXECUTE FUNCTION event_trigger_disable_test__noop();

CREATE ROLE event_trigger_disable_test__role;
GRANT USAGE ON SCHEMA _object_reference TO event_trigger_disable_test__role;
GRANT EXECUTE ON FUNCTION _object_reference._event_trigger__lock(name) TO event_trigger_disable_test__role;

SELECT plan(
  0
  +7 -- multi-trigger disable/enable preserves each one's own prior state
  +4 -- the sentinel exists while a call is in effect and is gone, function included, after enable()
  +1 -- enable() without a matching disable() is rejected
  +1 -- disable() rejects an unknown event trigger name
  +1 -- disable() rejects a duplicate name in its own argument list
  +3 -- disable() rejects a NULL array, an empty array and a NULL element
  +4 -- names passed unsorted are processed in "C" order
  +2 -- _event_trigger__lock() reads the state unlocked for a role that cannot row-lock the catalog
  +5 -- disabling zzz_object_reference_capture stops capture until enable()
  +9 -- commit check: a disable() without enable() fails at commit (also under replica), a normal pair does not, and SET CONSTRAINTS ALL IMMEDIATE fails between disable() and enable() and passes after
  +4 -- closing sequence: a stray sentinel event trigger is rejected, no state table is created, disable() succeeds once the stray is dropped, then a nested disable() is rejected
  +2 -- schema-qualification (search_path)
);

-- Multi-trigger disable/enable, preserving each trigger's own prior state
SELECT lives_ok(
  $$ALTER EVENT TRIGGER event_trigger_disable_test__b DISABLE$$
  , 'manually disable test trigger b ahead of time'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,event_trigger_disable_test__b}')$$
  , 'disable() both test triggers'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a')
  , 'D'
  , 'test trigger a is disabled while a call is in effect'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__b')
  , 'D'
  , 'test trigger b is (still) disabled while a call is in effect'
);
SELECT is(
  (SELECT evtevent || ' ' || evtenabled::text FROM pg_catalog.pg_event_trigger WHERE evtname = '__object_reference__event_trigger_sentinel')
  , 'ddl_command_end O'
  , 'the sentinel event trigger is enabled on ddl_command_end while a call is in effect'
);
SELECT has_function(
  (SELECT nspname FROM pg_catalog.pg_namespace WHERE oid = pg_catalog.pg_my_temp_schema())
  , '__object_reference__event_trigger_sentinel'
  , '{}'::name[]
  , 'the sentinel function exists while a call is in effect'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() restores both'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a')
  , 'O'
  , 'test trigger a is back to its original (origin) state'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__b')
  , 'D'
  , 'test trigger b is still disabled -- its prior state was preserved, not assumed enabled'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger WHERE evtname = '__object_reference__event_trigger_sentinel')
  , 'enable() dropped the sentinel event trigger'
);
SELECT hasnt_function(
  (SELECT nspname FROM pg_catalog.pg_namespace WHERE oid = pg_catalog.pg_my_temp_schema())
  , '__object_reference__event_trigger_sentinel'
  , '{}'::name[]
  , 'enable() dropped the sentinel function'
);

-- enable() without a matching disable()
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , '55000'
  , 'event_trigger__enable() called without a matching event_trigger__disable()'
  , 'enable() without disable() is rejected'
);

-- Unknown event trigger name
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,no_such_event_trigger}')$$
  , '42704'
  , 'event trigger "no_such_event_trigger" does not exist'
  , 'disable() rejects an unknown event trigger name'
);

-- Duplicate name in the same call
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,event_trigger_disable_test__a}')$$
  , '22023'
  , 'event_trigger_names contains a duplicate name'
  , 'disable() rejects a duplicate name in its own argument list'
);

/*
 * Argument errors are reported by disable() itself; any state change made
 * before the error would be rolled back with the call, so these tests cannot
 * observe whether validation ran before a side effect.
 */
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable(NULL)$$
  , '22023'
  , 'event_trigger_names must be a non-empty array'
  , 'disable() rejects a NULL array'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{}')$$
  , '22023'
  , 'event_trigger_names must be a non-empty array'
  , 'disable() rejects an empty array'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,NULL}')$$
  , '22023'
  , 'event_trigger_names contains a NULL name'
  , 'disable() rejects a NULL element'
);

-- Unsorted input is processed in "C" order
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__z,event_trigger_disable_test__a,"event_trigger_disable_test__B"}')$$
  , 'disable() with unsorted names'
);
SELECT results_eq(
  $$SELECT evtname FROM pg_temp.__object_reference__event_trigger_state ORDER BY ctid$$
  , $$VALUES ('event_trigger_disable_test__B'::name), ('event_trigger_disable_test__a'), ('event_trigger_disable_test__z')$$
  , 'names were processed in "C" collation order, not input order'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() after unsorted disable()'
);
SELECT results_eq(
  $$SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname IN ('event_trigger_disable_test__B', 'event_trigger_disable_test__a', 'event_trigger_disable_test__z')$$
  , $$VALUES ('O'::"char"), ('O'), ('O')$$
  , 'all three restored'
);

/*
 * A role without UPDATE on the catalog gets the trigger's state read
 * unlocked, with a WARNING naming the trigger, instead of an error. The DO
 * block runs as that role, and first proves the role really cannot FOR UPDATE
 * the catalog. The WARNING is suppressed to keep it out of the expected output.
 */
SELECT current_setting('client_min_messages') AS saved_client_min_messages \gset
SET client_min_messages = error;
SELECT lives_ok(
  $t$DO $do$
    BEGIN
      SET LOCAL ROLE event_trigger_disable_test__role;
      BEGIN
        PERFORM 1 FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a' FOR UPDATE;
        RAISE 'test role unexpectedly able to row-lock pg_event_trigger';
      EXCEPTION WHEN insufficient_privilege THEN NULL;
      END;
      PERFORM set_config('event_trigger_disable_test.enabled'
        , _object_reference._event_trigger__lock('event_trigger_disable_test__a')::text, true);
      RESET ROLE;
    END
  $do$$t$
  , 'helper does not fail for a role that cannot row-lock the catalog'
);
SET client_min_messages = :'saved_client_min_messages';
SELECT is(
  current_setting('event_trigger_disable_test.enabled')
  , 'O'
  , 'helper still returns the trigger''s evtenabled'
);

-- Disabling zzz_object_reference_capture stops capture until enable()
SELECT lives_ok(
  $$SELECT object_reference.capture__start(object_reference.object_group__create('event_trigger_disable_test_group'))$$
  , 'start a capture group'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{zzz_object_reference_capture}')$$
  , 'disable() zzz_object_reference_capture'
);
CREATE TABLE public.event_trigger_disable_test__while_disabled();
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() restores zzz_object_reference_capture'
);
CREATE TABLE public.event_trigger_disable_test__after_enable();
SELECT results_eq(
  $$SELECT array_to_string(o.object_names, '.')
    FROM _object_reference.object_group__object m
      JOIN _object_reference.object o USING (object_id)
    WHERE m.object_group_id = (object_reference.object_group__get('event_trigger_disable_test_group')).object_group_id$$
  , $$VALUES ('public.event_trigger_disable_test__after_enable')$$
  , 'only the table created after enable() was captured'
);
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('event_trigger_disable_test_group')$$
  , 'stop the capture group'
);

-- Commit check: SET CONSTRAINTS ... IMMEDIATE runs the same check COMMIT would
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() for the commit check'
);
SELECT throws_ok(
  $$SET CONSTRAINTS pg_temp.__object_reference__event_trigger_state_check IMMEDIATE$$
  , '55000'
  , 'transaction committed without event_trigger__enable() after event_trigger__disable()'
  , 'the commit check fails while enable() has not run'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() after the failed check'
);

-- replica is set before disable(): only ENABLE ALWAYS on the check trigger lets its queued event fire
SET LOCAL session_replication_role = replica;
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() under session_replication_role = replica'
);
SELECT throws_ok(
  $$SET CONSTRAINTS pg_temp.__object_reference__event_trigger_state_check IMMEDIATE$$
  , '55000'
  , 'transaction committed without event_trigger__enable() after event_trigger__disable()'
  , 'the commit check also fails under session_replication_role = replica'
);
SET LOCAL session_replication_role = origin;
SELECT throws_ok(
  $$SET CONSTRAINTS ALL IMMEDIATE$$
  , '55000'
  , 'transaction committed without event_trigger__enable() after event_trigger__disable()'
  , 'SET CONSTRAINTS ALL IMMEDIATE between disable() and enable() raises'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() after the failed checks'
);
SELECT lives_ok(
  $$SET CONSTRAINTS ALL IMMEDIATE$$
  , 'the commit check passes after enable()'
);
SELECT hasnt_table(
  '__object_reference__event_trigger_state'
  , 'enable() dropped the state table'
);

-- Must stay last: this sequence leaves a disable() call in effect.
CREATE EVENT TRIGGER __object_reference__event_trigger_sentinel ON ddl_command_end EXECUTE FUNCTION event_trigger_disable_test__noop();
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , '55000'
  , 'event_trigger__disable() from another session is still in effect'
  , 'disable() rejects an existing sentinel event trigger'
);
SELECT hasnt_table(
  '__object_reference__event_trigger_state'
  , 'the rejected disable() created no state table'
);
DROP EVENT TRIGGER __object_reference__event_trigger_sentinel;
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() succeeds once the stray sentinel is gone (also after SET CONSTRAINTS ALL IMMEDIATE: the check trigger starts out deferred)'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , '55000'
  , 'event_trigger__disable() called while a previous call is still in effect'
  , 'a second disable() without enable() in between is rejected'
);

\i test/finish.sql
\echo # WARNING: this test assumes it runs in a transaction that is never committed; if you ran it by hand in psql, ROLLBACK now.

-- vi: expandtab sw=2 ts=2

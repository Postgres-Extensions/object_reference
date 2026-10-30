\set ECHO none

\i test/load.sql

/*
 * event_trigger__disable()/__enable() are ALTER EVENT TRIGGER under the
 * hood -- ordinary transactional DDL, invisible to other sessions until
 * commit, same as any other catalog change (verified empirically: a
 * concurrent session neither blocks on, nor otherwise sees, another
 * session's still-uncommitted DISABLE). The real risk is two sessions both
 * altering the SAME event trigger concurrently, so this test exercises the
 * mechanism against its OWN dummy event triggers rather than the real zzz_*
 * ones, to keep it independent of whatever else happens to run concurrently
 * in this same parallel test batch.
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
  +3 -- nested disable() without an intervening enable() is rejected
  +1 -- enable() without a matching disable() is rejected
  +1 -- disable() rejects an unknown event trigger name
  +1 -- disable() rejects a duplicate name in its own argument list
  +3 -- disable() rejects a NULL array, an empty array and a NULL element
  +8 -- argument errors are reported in preference to the "previous call in effect" error
  +4 -- names passed unsorted are processed in "C" order
  +3 -- _event_trigger__lock() falls back to an advisory lock for a role that cannot row-lock the catalog
  +5 -- zzz_object_reference_capture self-recognizes and stands down while a disable() is in effect
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

-- Nested disable() without an intervening enable()
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() the first time'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , NULL
  , 'event_trigger__disable() called while a previous call is still in effect'
  , 'a second disable() without enable() in between is rejected'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() cleans up so later tests are unaffected'
);

-- enable() without a matching disable()
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , NULL
  , 'event_trigger__enable() called without a matching event_trigger__disable()'
  , 'enable() without disable() is rejected'
);

-- Unknown event trigger name
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,no_such_event_trigger}')$$
  , NULL
  , 'event trigger "no_such_event_trigger" does not exist'
  , 'disable() rejects an unknown event trigger name'
);

-- Duplicate name in the same call
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,event_trigger_disable_test__a}')$$
  , NULL
  , 'event_trigger_names contains a duplicate name'
  , 'disable() rejects a duplicate name in its own argument list'
);

/*
 * Argument errors are reported by disable() itself; any state change made
 * before the error would be rolled back with the call, so these tests cannot
 * observe whether validation ran before a side effect. What they can observe
 * is which error wins when several apply (see the precedence tests below).
 */
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable(NULL)$$
  , NULL
  , 'event_trigger_names must be a non-empty array'
  , 'disable() rejects a NULL array'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{}')$$
  , NULL
  , 'event_trigger_names must be a non-empty array'
  , 'disable() rejects an empty array'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a,NULL}')$$
  , NULL
  , 'event_trigger_names contains a NULL name'
  , 'disable() rejects a NULL element'
);

-- Argument errors are reported even while a previous call is in effect
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() so a call is in effect'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__b,event_trigger_disable_test__b}')$$
  , NULL
  , 'event_trigger_names contains a duplicate name'
  , 'duplicate name is reported before the in-effect error'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{no_such_event_trigger}')$$
  , NULL
  , 'event trigger "no_such_event_trigger" does not exist'
  , 'unknown name is reported before the in-effect error'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable(NULL)$$
  , NULL
  , 'event_trigger_names must be a non-empty array'
  , 'NULL array is reported before the in-effect error'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{}')$$
  , NULL
  , 'event_trigger_names must be a non-empty array'
  , 'empty array is reported before the in-effect error'
);
SELECT throws_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__b,NULL}')$$
  , NULL
  , 'event_trigger_names contains a NULL name'
  , 'NULL element is reported before the in-effect error'
);
SELECT is(
  (SELECT array_agg(evtname) FROM pg_temp.__object_reference__event_trigger_state)
  , '{event_trigger_disable_test__a}'::name[]
  , 'the call still in effect kept its own state'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() ends that call'
);

-- Unsorted input is processed in "C" order
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__z,event_trigger_disable_test__a,"event_trigger_disable_test__B"}')$$
  , 'disable() with unsorted names'
);
SELECT is(
  (SELECT array_agg(evtname ORDER BY ctid) FROM pg_temp.__object_reference__event_trigger_state)
  , '{event_trigger_disable_test__B,event_trigger_disable_test__a,event_trigger_disable_test__z}'::name[]
  , 'names were processed in "C" collation order, not input order'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() after unsorted disable()'
);
SELECT is(
  (SELECT array_agg(evtenabled ORDER BY evtname COLLATE "C") FROM pg_catalog.pg_event_trigger WHERE evtname LIKE 'event\_trigger\_disable\_test\_\_%' AND evtname IN ('event_trigger_disable_test__B', 'event_trigger_disable_test__a', 'event_trigger_disable_test__z'))
  , '{O,O,O}'::"char"[]
  , 'all three restored'
);

/*
 * A role that cannot row-lock pg_event_trigger (as on managed services
 * without true superuser) gets an advisory lock instead of an error. The DO
 * block runs as that role, and first proves the role really cannot FOR UPDATE
 * the catalog.
 */
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
SELECT is(
  current_setting('event_trigger_disable_test.enabled')
  , 'O'
  , 'helper still returns the trigger''s evtenabled'
);
SELECT is(
  (SELECT count(*)::int FROM pg_locks
    WHERE locktype = 'advisory'
      AND pid = pg_backend_pid()
      AND classid::int = 'pg_catalog.pg_event_trigger'::regclass::oid::int
      AND objid::int = (SELECT oid::int FROM pg_catalog.pg_event_trigger WHERE evtname = 'event_trigger_disable_test__a')
      AND objsubid = 2)
  , 1
  , 'helper took the advisory lock keyed on catalog and trigger oid'
);

/*
 * zzz_object_reference_capture / zzz_object_reference__fix_identity check
 * for an event_trigger__disable() call currently in effect for THIS
 * session (regardless of which trigger names it names) and stand down --
 * verify that here for capture, since it's directly observable.
 */
SELECT lives_ok(
  $$SELECT object_reference.capture__start(object_reference.object_group__create('event_trigger_disable_test_group'))$$
  , 'start a capture group'
);
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__disable('{event_trigger_disable_test__a}')$$
  , 'disable() (any trigger) also signals self-recognizing triggers to stand down'
);
CREATE TABLE event_trigger_disable_test_table();
SELECT lives_ok(
  $$SELECT _object_reference.event_trigger__enable()$$
  , 'enable() ends that window'
);
SELECT is_empty(
  $$
    SELECT 1
      FROM _object_reference.object_group__object
      WHERE object_group_id = (object_reference.object_group__get('event_trigger_disable_test_group')).object_group_id
  $$
  , 'the table created while disable() was in effect was NOT captured'
);
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('event_trigger_disable_test_group')$$
  , 'stop the capture group'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2

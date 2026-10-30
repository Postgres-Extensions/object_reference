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

SELECT plan(
  0
  +7 -- multi-trigger disable/enable preserves each one's own prior state
  +3 -- nested disable() without an intervening enable() is rejected
  +1 -- enable() without a matching disable() is rejected
  +1 -- disable() rejects an unknown event trigger name
  +1 -- disable() rejects a duplicate name in its own argument list
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
  $$SELECT _object_reference.event_trigger__disable('{no_such_event_trigger}')$$
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

\set ECHO none

\i test/load.sql

SELECT plan(
  0
  +4 -- default begin/end round-trip disables, then restores, the trigger
  +4 -- begin/end preserves a non-default prior state instead of assuming enabled
  +3 -- nested begin() without an intervening end() is rejected
  +1 -- end() without a matching begin() is rejected
  +1 -- begin() rejects an unknown event trigger name
  +2 -- schema-qualification (search_path)
);

-- Default begin/end round-trip
SELECT lives_ok(
  $$SELECT _object_reference.internal_update__begin()$$
  , 'internal_update__begin() disables the default trigger'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz__object_reference_drop')
  , 'D'
  , 'zzz__object_reference_drop is disabled while an internal update is in progress'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_update__end()$$
  , 'internal_update__end() re-enables it'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz__object_reference_drop')
  , 'O'
  , 'zzz__object_reference_drop is back to its original (origin) state'
);

-- Preserve a non-default prior state (already disabled for unrelated reasons)
SELECT lives_ok(
  $$ALTER EVENT TRIGGER zzz_object_reference_capture DISABLE$$
  , 'manually disable zzz_object_reference_capture ahead of time'
);
SELECT lives_ok(
  $$
    SELECT _object_reference.internal_update__begin('{zzz_object_reference_capture}');
    SELECT _object_reference.internal_update__end();
  $$
  , 'begin()/end() round-trip on an already-disabled trigger'
);
SELECT is(
  (SELECT evtenabled FROM pg_catalog.pg_event_trigger WHERE evtname = 'zzz_object_reference_capture')
  , 'D'
  , 'still disabled afterward -- its prior state was preserved, not assumed enabled'
);
SELECT lives_ok(
  $$ALTER EVENT TRIGGER zzz_object_reference_capture ENABLE$$
  , 'restore zzz_object_reference_capture for later tests'
);

-- Nested begin() without an intervening end()
SELECT lives_ok(
  $$SELECT _object_reference.internal_update__begin()$$
  , 'begin() the first time'
);
SELECT throws_ok(
  $$SELECT _object_reference.internal_update__begin()$$
  , NULL
  , 'internal_update__begin() called while already in an internal update'
  , 'a second begin() without end() in between is rejected'
);
SELECT lives_ok(
  $$SELECT _object_reference.internal_update__end()$$
  , 'end() cleans up so later tests are unaffected'
);

-- end() without a matching begin()
SELECT throws_ok(
  $$SELECT _object_reference.internal_update__end()$$
  , NULL
  , 'internal_update__end() called without a matching internal_update__begin()'
  , 'end() without begin() is rejected'
);

-- Unknown event trigger name
SELECT throws_ok(
  $$SELECT _object_reference.internal_update__begin('{no_such_event_trigger}')$$
  , NULL
  , 'event trigger "no_such_event_trigger" does not exist'
  , 'begin() rejects an unknown event trigger name'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2

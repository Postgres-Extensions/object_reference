\set ECHO none

\i test/pgxntool/setup.sql

/*
 * SEE ALSO sql/all.sql!
 */

SET search_path=test_capture, test_capture_support, tap, public;

/*
 * NOTE: If you get a 'relation "test_object" does not exist' error that
 * probably means you dumped an empty database!
 */
SELECT plan( 
  1 -- Verify captured object IDs match

  + (
  0
  + cna -- test_capture verify
  + c * 2 -- test_capture drop
  + (SELECT count(*) FROM object_group_ids) + 1 -- drop capture groups
  + c * 2 -- test_capture drop #2

  + c -- verify
  + c * 2 -- drop
  )::int

  + 1 -- verify object table is now empty
)
  FROM (SELECT count(*) c, count(CASE WHEN create_command NOT LIKE 'ALTER%' THEN 1 END) AS cna
    FROM test_object) c
;

SET client_min_messages = WARNING; -- Drop is noisy
--SET client_min_messages = DEBUG;
SELECT isnt_empty(
  'SELECT * FROM test_capture_support.obj_ref'
  , 'obj_ref is not empty'
);
SELECT isnt_empty(
  'SELECT * FROM test_capture_support.og_o WHERE n = 1'
  , 'og_o is not empty'
);
SELECT bag_eq(
  $$SELECT object_id FROM test_capture_support.og_o WHERE n = 1$$
  , $$SELECT object_id FROM test_capture_support.obj_ref$$
  , 'Verify captured object IDs match'
);

SELECT c.*
  FROM test_capture_support.test_object o, test_capture_support.test__verify(o) c
  WHERE create_command NOT LIKE 'ALTER%'
  ORDER BY o.seq ASC
;


/*
 * First verify that object group prevents drop
 * (see below too)
 */
SELECT c.*
  FROM test_capture_support.test_object o
    --, test_capture_support.test__drop(o) c
    , test_capture_support.test__drop(o, 'object_group__object', 'object_group__object_object_id_fkey') c
  WHERE create_command NOT LIKE 'ALTER%'
  ORDER BY o.seq DESC -- NEEDS to be DESC!
;

-- Drop capture groups
SELECT throws_ok(
  format( $$SELECT object_reference.object_group__remove(%s, false)$$, n )
  , '23503'
  , 'update or delete on table "object_group" violates foreign key constraint "object_group__object_object_group_id_fkey" on table "object_group__object"'
  , 'Remove object group 1 should fail' || n
) FROM object_group_ids WHERE n = 1
;
SELECT lives_ok(
  format( $$SELECT object_reference.object_group__remove(%s, true)$$, n )
  , 'Remove object group ' || n
) FROM object_group_ids
;

/*
 * Drop objects for real this time
 * (see above too)
 */
SELECT c.*
  FROM test_capture_support.test_object o
    , test_capture_support.test__drop(o) c
    --, test_capture_support.test__drop(o, 'object_group__object', 'object_group__object_object_id_fkey') c
  WHERE create_command NOT LIKE 'ALTER%'
  ORDER BY o.seq DESC -- NEEDS to be DESC!
;

/*
 * Non-capture tests
 */
SET search_path=test_objects, test_support, tap, public;
SELECT c.* FROM test_object o, test__verify(o) c ORDER BY o.seq ASC;
SELECT c.* FROM test_object o, test__drop(o) c ORDER BY o.seq DESC;

SELECT is_empty(
  $$SELECT * FROM obj_ref$$
  , 'No object references remain'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2

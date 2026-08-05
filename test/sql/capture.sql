\set ECHO none

\i test/load.sql

/*
 * SEE ALSO dump/load_all.sql and dump/verify.sql!
 */

CREATE SCHEMA test_support;
SET search_path = test_support, tap, public;

\i test/helpers/object_table.sql

CREATE SCHEMA object_identity_temp_test_schema; -- THIS NEEDS TO FAIL IF THE SCHEMA EXISTS!
SET search_path=object_identity_temp_test_schema,test_support, tap, public;

CREATE TABLE object_group_ids(n int, object_group_id int);
CREATE TEMP VIEW og_o AS
  SELECT n, ogo.*
    FROM _object_reference.object_group__object ogo
      JOIN object_group_ids ogi USING(object_group_id)
;

SELECT plan( (
  0
  
  + (SELECT count(*) FROM test_prereq)
  + 1 -- capture__stop when not capturing

  + 2 -- create groups

  + 2 -- start capture

  + c -- create

  + 3 -- Manually register an object; make certain it does not show up in group

  + cna + 2 -- verify #1

  + 3 -- Group 2

  + 1 -- Invalid capture group

  + 3 -- Stop group 2
  + 3 -- Stop group 1

  -- drop
  + 2 -- Drop groups
    + cna * 2 -- Drop objects
    + 1 -- Verify object_group_ids still has correct count
    + 1 -- verify object table is now empty
    + 1 -- schema-qualification (search_path)
)::int )
  FROM (SELECT count(*) c, count(CASE WHEN create_command NOT LIKE 'ALTER%' THEN 1 END) AS cna
    FROM test_object) c
;

SELECT lives_ok(
      command
      , 'prereq: ' || command
    )
  FROM test_prereq
;

SELECT throws_ok(
  $$SELECT object_reference.capture__stop('')$$
  , 'P0002'
  , 'object group "" does not exist'
  , 'Verify capture__stop() without capture__start errors.'
);

-- Create groups
SELECT lives_ok(
  format(
    $$INSERT INTO object_group_ids VALUES(
        %1$s
        , object_reference.object_group__create('TEMP object capture test group %1$s')
      )
    $$
    , n
  )
  , format('Create "TEMP object capture test group %s"', n)
) FROM generate_series(1,2) n(n);

-- Start capture
SELECT is(
  object_reference.capture__start('TEMP object capture test group 1')
  , 1 -- Next level #
  , 'Start capture for group 1'
);
SELECT is_empty(
  $$SELECT * FROM og_o$$
  , 'No objects exist for either test group'
);

-- Create
SELECT c.* FROM test_object o, test__create(o) c ORDER BY o.seq ASC;

-- Manually register an object; make certain it does not show up in group
-- NOTE! Other tests depend on this working!
SELECT lives_ok(
  $$CREATE TEMP TABLE ogi__object_id AS
      SELECT object_reference.object__getsert('table', 'object_group_ids', NULL) AS object_id
  $$
  , 'Register object_group_ids table'
);
SELECT is(
  (SELECT count(*) FROM ogi__object_id)
  , 1::bigint
  , 'Verify ogi__object_id has exactly one row.'
);
SELECT is_empty(
  $$SELECT row_to_json(og_o.*)
      FROM _object_reference.object_group__object og_o
        JOIN ogi__object_id USING(object_id)
  $$
  , 'Verify object_id for object_group_ids table is NOT in any groups.'
);

-- Verify #1
SELECT is(
  (SELECT count(*) FROM og_o WHERE n=1)
  , (SELECT count(*) FROM test_object
      WHERE create_command NOT LIKE 'ALTER%'
  )
  , 'Correct # of objects captured to group.'
);
SELECT c.*
  FROM test_object o, test__register(o) c
  WHERE create_command NOT LIKE 'ALTER%'
  ORDER BY o.seq
;
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 1$$
  , $$SELECT object_id FROM obj_ref$$
  , 'Verify captured object IDs match'
);
/* EXCLUDED CODE
SELECT * FROM og_o;
SELECT * FROM _object_reference.object;-- WHERE object_id IN(6,9);
*/

-- Group 2
SELECT is(
  object_reference.capture__start('TEMP object capture test group 2')
  , 2
  , 'Start capture for group 2'
);
CREATE TABLE "Capture 2"();
CREATE VIEW "Capture 2 View" AS SELECT 1;
CREATE TEMP TABLE cap2 AS SELECT * FROM (VALUES
  ('table'::cat_tools.object_type, '"Capture 2"')
  , ('view', '"Capture 2 View"')
) v(object_type, object_name)
;

SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 2$$
  , $$SELECT object_reference.object__getsert(object_type, object_name, NULL) FROM cap2$$
  , 'Verify captured objects for level 2'
);
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 1$$
  , $$SELECT object_id FROM obj_ref$$
  , 'Verify group 1 objects have not changed.'
);

-- Invalid capture group
SELECT throws_ok(
  $$SELECT object_reference.capture__stop('TEMP object capture test group DOES NOT EXIST')$$
  , 'P0002' -- Should probably change this...
  , 'object group "TEMP object capture test group DOES NOT EXIST" does not exist'
  , 'capture__stop() with invalid group errors'
);

-- Stop group 2
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('TEMP object capture test group 2')$$
  , 'Stop capture group 2'
);

CREATE TABLE "Capture 1"();
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 1$$
  , $$SELECT object_id FROM obj_ref
    UNION SELECT object_reference.object__getsert('table', '"Capture 1"', NULL )
  $$
  , 'Verify table "Capture 1" added to capture group 1'
);
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 2$$
  , $$SELECT object_reference.object__getsert(object_type, object_name, NULL) FROM cap2$$
  , 'Verify captured objects for level 2 are unchanged'
);

-- Stop group 1
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('TEMP object capture test group 1')$$
  , 'Stop capture group 1'
);
CREATE TABLE "Capture 3"();
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 1$$
  , $$SELECT object_id FROM obj_ref
    UNION SELECT object_reference.object__getsert('table', '"Capture 1"', NULL )
  $$
  , 'Verify capture group 1 is still correct'
);
SELECT bag_eq(
  $$SELECT object_id FROM og_o WHERE n = 2$$
  , $$SELECT object_reference.object__getsert(object_type, object_name, NULL) FROM cap2$$
  , 'Verify capture group 2 is still correct'
);

--SET client_min_messages = DEBUG;
SELECT lives_ok(
  format( $$SELECT object_reference.object_group__remove(%s, true)$$, n )
  , 'Remove object group ' || n
) FROM object_group_ids
;
SELECT c.*
  FROM test_object o, test__drop(o) c
  WHERE create_command NOT LIKE 'ALTER%'
  ORDER BY o.seq DESC -- NEEDS to be DESC!
;

SELECT is(
  (SELECT count(*)::int FROM object_group_ids)
  , 2
  , 'object_group_ids still has correct record count'
);
  
SELECT is_empty(
  $$SELECT * FROM og_o$$
  , 'No object references remain'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2

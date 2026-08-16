\set ECHO none

\i test/load.sql

/*
 * SEE ALSO sql/all.sql!
 */

CREATE SCHEMA test_support;
SET search_path = test_support, tap, public;
\i test/helpers/object_table.sql

CREATE SCHEMA test_objects; -- THIS NEEDS TO FAIL IF THE SCHEMA EXISTS!
SET search_path=test_objects, test_support, tap, public;


SELECT plan( (
  0
  
  + (SELECT count(*) FROM test_prereq)
  + c -- create

  + c -- register
  + c -- verify

  /*
   * Capture stuff
   */
  + (SELECT count(*) FROM test_prereq)
  + 1 -- Create group

  + (SELECT count(*) FROM test_prereq)
  + c -- create

  --+ c -- register
  + cna + 1 -- verify

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

SELECT c.* FROM test_object o, test__create(o) c ORDER BY o.seq ASC;

SELECT c.* FROM test_object o, test__register(o) c ORDER BY o.seq DESC; -- Would be nice to randomize...
SELECT c.* FROM test_object o, test__verify(o) c ORDER BY o.seq ASC;

CREATE SCHEMA test_capture_support;
SET search_path = test_capture_support, tap, public;

/*
 * Create table to remember our object group. NOTE: make sure to do this in the
 * test_capture_support schema!
 */
CREATE TABLE object_group_ids(n int, object_group_id int);
CREATE VIEW og_o AS
  SELECT n, ogo.*
    FROM _object_reference.object_group__object ogo
      JOIN object_group_ids ogi USING(object_group_id)
;

\i test/helpers/object_table.sql

/*
 * Now, test creating objects via capture__start()
 */
CREATE SCHEMA test_capture; -- THIS NEEDS TO FAIL IF THE SCHEMA EXISTS!
SET search_path=test_capture, test_capture_support, tap, public;

-- Run prereqs
SELECT lives_ok(
      command
      , 'prereq: ' || command
    )
  FROM test_prereq
;

-- Create groups
SELECT lives_ok(
  format(
    $$INSERT INTO object_group_ids VALUES(
        %1$s
        , object_reference.object_group__create('object capture test group %1$s')
      )
    $$
    , n
  )
  , format('Create "object capture test group %s"', n)
) FROM generate_series(1,2) n(n);

-- Start capture
SELECT is(
  object_reference.capture__start('object capture test group 1')
  , 1 -- Next level #
  , 'Start capture for group 1'
);
SELECT is_empty(
  $$SELECT * FROM og_o$$
  , 'No objects exist for either test group'
);

-- Create
SELECT c.* FROM test_object o, test__create(o) c ORDER BY o.seq ASC;

-- Stop group 1
SELECT lives_ok(
  $$SELECT object_reference.capture__stop('object capture test group 1')$$
  , 'Stop capture group 1'
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

SELECT finish();
COMMIT;

-- vi: expandtab sw=2 ts=2

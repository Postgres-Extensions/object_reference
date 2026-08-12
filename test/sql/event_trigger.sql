\set ECHO none

\i test/load.sql

CREATE SCHEMA object_identity_temp_test_schema; -- THIS NEEDS TO FAIL IF THE SCHEMA EXISTS!
SET search_path=object_identity_temp_test_schema,tap,public;

CREATE TABLE table_under_test(column_test int, filler int);
CREATE TABLE test2(col int);

SELECT plan(
  0
  +3 -- objects setup
  +4 * 2 -- column_test
  +4 -- table_test

  +2 + 3 -- column rename
  +4 + 3 -- schema rename
  +3 + 3 -- table rename

  +2 + 1 -- column drop
  +3 -- table drop
  +3 -- schema drop
  +2 -- schema-qualification (search_path)
);

SELECT lives_ok(
  $$CREATE TEMP TABLE objects AS
      SELECT * FROM _object_reference._object_v__for_update('schema', 'object_identity_temp_test_schema'::regnamespace, 0)
      UNION ALL
      SELECT * FROM _object_reference._object_v__for_update('table', 'test2'::regclass, 0)
      UNION ALL
      SELECT * FROM _object_reference._object_v__for_update('table column', 'test2'::regclass, 1)
  $$
  , 'Register schema-drop test objects'
);
SELECT lives_ok(
  $$CREATE TEMP VIEW objects_view AS SELECT o.* FROM _object_reference._object_v o JOIN objects t USING(object_id)$$
  , 'Create objects_view'
);
SELECT is(
  (SELECT count(*) FROM objects_view)
  , 3::bigint
  , 'Exactly 3 test view records'
);


/*
 * column_test
 */
SELECT lives_ok(
  $$CREATE TEMP TABLE column_test AS SELECT * FROM _object_reference._object_v__for_update('table column', 'table_under_test'::regclass, 1)$$
  , $$CREATE TEMP TABLE column_test AS SELECT * FROM _object_reference._object_v__for_update('table column', 'table_under_test'::regclass, 1)$$
);
SELECT is(
  (SELECT count(*) FROM column_test)
  , 1::bigint
  , 'Exactly 1 test object record'
);
SELECT lives_ok(
  $$CREATE TEMP VIEW column_test_view AS SELECT o.* FROM _object_reference._object_v o JOIN column_test t USING(object_id)$$
  , 'Create column_test_view'
);
SELECT is(
  (SELECT count(*) FROM column_test_view)
  , 1::bigint
  , 'Exactly 1 test view record'
);

/*
 * s/column_test/column_filler/g
 * Change 1 to 2 in getsert
 */
SELECT lives_ok(
  $$CREATE TEMP TABLE column_filler AS SELECT * FROM _object_reference._object_v__for_update('table column', 'table_under_test'::regclass, 2)$$
  , $$CREATE TEMP TABLE column_filler AS SELECT * FROM _object_reference._object_v__for_update('table column', 'table_under_test'::regclass, 2)$$
);
SELECT is(
  (SELECT count(*) FROM column_filler)
  , 1::bigint
  , 'Exactly 1 test object record'
);
SELECT lives_ok(
  $$CREATE TEMP VIEW column_filler_view AS SELECT o.* FROM _object_reference._object_v o JOIN column_filler t USING(object_id)$$
  , 'Create column_filler_view'
);
SELECT is(
  (SELECT count(*) FROM column_filler_view)
  , 1::bigint
  , 'Exactly 1 test view record'
);

/*
 * table_test
 */
SELECT lives_ok(
  $$CREATE TEMP TABLE table_test AS SELECT * FROM _object_reference._object_v__for_update('table', 'table_under_test'::regclass, 0)$$
  , $$CREATE TEMP TABLE table_test AS SELECT * FROM _object_reference._object_v__for_update('table', 'table_under_test'::regclass, 0)$$
);
SELECT is(
  (SELECT count(*) FROM table_test)
  , 1::bigint
  , 'Exactly 1 test object record'
);
SELECT lives_ok(
  $$CREATE TEMP VIEW table_test_view AS SELECT o.* FROM _object_reference._object_v o JOIN table_test t USING(object_id)$$
  , 'Create table_test_view'
);
SELECT is(
  (SELECT count(*) FROM table_test_view)
  , 1::bigint
  , 'Exactly 1 test view record'
);

/*
 * Test helpers
 */
CREATE FUNCTION pg_temp.check_column(text)
RETURNS SETOF text LANGUAGE sql AS $body$
SELECT results_eq(
  $$SELECT * FROM column_test_view$$
  , $$SELECT * FROM column_test$$
  , 'test: ' || $1
)
UNION ALL
SELECT results_eq(
  $$SELECT * FROM column_filler_view$$
  , $$SELECT * FROM column_filler$$
  , 'filler: ' || $1
)
$body$;
CREATE FUNCTION pg_temp.check_table(text)
RETURNS SETOF text LANGUAGE sql AS $body$
SELECT results_eq(
  $$SELECT * FROM table_test_view$$
  , $$SELECT * FROM table_test$$
  , $1
)
$body$;
CREATE FUNCTION pg_temp.check_both(text)
RETURNS SETOF text LANGUAGE sql AS $body$
SELECT pg_temp.check_table('table_test: ' || $1)
UNION ALL
SELECT pg_temp.check_column('column_test: ' || $1)
$body$;


/*
 * Rename column
 */
SELECT lives_ok(
  $$ALTER TABLE table_under_test RENAME column_test TO test_column2$$
  , 'Rename column'
);
SELECT lives_ok(
  $$UPDATE column_test SET object_names[3] = 'test_column2'$$
  , 'Update column_test'
);
SELECT pg_temp.check_both('verify column rename');

-- Rename schema
SELECT lives_ok(
  $$ALTER SCHEMA object_identity_temp_test_schema RENAME TO test_schema2$$
  , 'Rename schema'
);
SET search_path=test_schema2,tap,public;
SELECT lives_ok(
  $$
    UPDATE objects SET object_names[0] = 'test_schema2' WHERE object_names[0] = 'object_identity_temp_test_schema';
    UPDATE objects SET object_names[1] = 'test_schema2' WHERE object_names[1] = 'object_identity_temp_test_schema';
  $$
  , 'Update objects table'
);
SELECT lives_ok(
  $$UPDATE table_test SET object_names[1] = 'test_schema2'$$
  , 'Update table_test'
);
SELECT lives_ok(
  $$
    UPDATE column_test SET object_names[1] = 'test_schema2';
    UPDATE column_filler SET object_names[1] = 'test_schema2';
  $$
  , 'Update column_test'
);
SELECT pg_temp.check_both('verify table rename');

-- Rename table
SELECT lives_ok(
  $$ALTER TABLE table_under_test RENAME TO test_table2$$
  , 'Rename table'
);
SELECT lives_ok(
  $$UPDATE table_test SET object_names[2] = 'test_table2'$$
  , 'Update table_test'
);
SELECT lives_ok(
  $$
    UPDATE column_test SET object_names[2] = 'test_table2';
    UPDATE column_filler SET object_names[2] = 'test_table2';
  $$
  , 'Update column_test'
);
SELECT pg_temp.check_both('verify table rename');

-- Drop column
SELECT lives_ok(
  $$ALTER TABLE test_table2 DROP test_column2$$
  , 'Drop column'
);
SELECT is_empty(
  $$SELECT * FROM column_test_view$$
  , 'Verify column record is deleted'
);
SELECT pg_temp.check_table('Verify table record is unchanged');

-- Drop table
SELECT lives_ok(
  $$DROP TABLE test_table2$$
  , 'Drop table'
);
SELECT is_empty(
  $$SELECT * FROM table_test_view$$
  , 'Verify table record is deleted'
);
SELECT is_empty(
  $$SELECT * FROM column_filler_view$$
  , 'Verify filler column record is deleted'
);

-- Drop schema
SELECT results_eq(
  $$SELECT * FROM objects_view$$
  , $$SELECT * FROM objects$$
  , 'Verify objects still registered correctly'
);
SELECT lives_ok(
  $$DROP SCHEMA test_schema2 CASCADE$$
  , 'Drop schema'
);
SELECT is(
  (SELECT count(*) FROM objects_view)
  , 0::bigint
  , 'objects_view is empty'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2

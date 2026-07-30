\set ECHO none

\i test/load.sql

CREATE TABLE test_table();

SELECT plan(
  0
  +1 -- schema
  +3 -- initial
  +2 -- new functions
  +3 -- errors (includes temp object test)
  +1 -- create extensions
);

-- Schema
SELECT schema_privs_are(
  '_object_reference'
  , 'object_reference__dependency'
  , array[ 'USAGE' ]
);

SELECT table_privs_are(
  '_object_reference', 'object'
  , 'object_reference__dependency'
  , '{REFERENCES}'::text[]
);

-- Initial
SELECT lives_ok(
  $$CREATE TEMP TABLE test_object AS SELECT object_reference.object__getsert('table', 'test_table') AS object_id;$$
  , $$CREATE TEMP TABLE test_object AS SELECT object_reference.object__getsert('table', 'test_table') AS object_id;$$
);
SELECT is(
  (SELECT object_oid FROM _object_reference._object_v WHERE object_id = (SELECT object_id FROM test_object))
  , 'test_table'::regclass::oid
  , 'Verify object_oid field is correct'
);

-- Test object__describe function
SELECT is(
  object_reference.object__describe((SELECT object_id FROM test_object))
  , pg_catalog.pg_describe_object('pg_class'::regclass, 'test_table'::regclass, 0)
  , 'object__describe returns same result as pg_describe_object'
);

-- Test object__identity function  
SELECT results_eq(
  $$SELECT * FROM object_reference.object__identity((SELECT object_id FROM test_object))$$
  , $$SELECT type, schema, name, identity FROM pg_catalog.pg_identify_object('pg_class'::regclass, 'test_table'::regclass, 0)$$
  , 'object__identity returns same result as pg_identify_object'
);
SELECT is(
  object_reference.object__getsert('table', 'test_table')
  , (SELECT object_id FROM test_object)
  , 'Existing object works, provides correct ID'
);

-- errors
SELECT throws_ok(
  $$SELECT object_reference.object__getsert('table', 'test_table', secondary:='test')$$
  , NULL
  , 'secondary may not be specified for table objects'
  , 'secondary may not be specified for table objects'
);

-- Test temp object rejection
CREATE TEMP TABLE temp_test_table();
SELECT throws_ok(
  $$SELECT object_reference.object__getsert('table', 'temp_test_table')$$
  , '0A000' -- feature_not_supported
  , 'cannot track temporary object'
  , 'temp objects are rejected'
);

-- Create extensions
SELECT lives_ok(
  $$CREATE EXTENSION test_factory$$
  , $$CREATE EXTENSION test_factory$$
);
  
\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2

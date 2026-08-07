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

SELECT plan( (
  0
  + 1 -- Ensure everything's being tested
  + 1 -- Verify unsupported
  
  + (SELECT count(*) FROM test_prereq)
  + c -- create

  + c -- register
  + c -- verify

  + c * 2 -- drop

  + 1 -- verify object table is now empty
)::int )
  FROM (SELECT count(*) c FROM test_object) c
;

-- Ensure we're hitting everything
SELECT bag_eq(
  $$
SELECT object_type FROM test_object
UNION ALL
SELECT * FROM object_reference.untested_srf()
UNION ALL
SELECT * FROM object_reference.unsupported_srf()
UNION ALL SELECT 'schema' -- Tested via other means
$$
  , $$SELECT e::cat_tools.object_type FROM cat_tools.enum_range_srf('cat_tools.object_type') e$$
  , 'All object types are being tested.'
);

-- Sanity-check our unsupported set
SELECT bag_eq(
  $$SELECT * FROM object_reference.unsupported_srf()$$
  , $$SELECT * FROM cat_tools.objects__shared_srf()
      UNION -- Intentionally not UNION ALL; we want to know if object_reference.unsupported has dupes
      SELECT * FROM cat_tools.objects__address_unsupported_srf()
      UNION SELECT 'event trigger'
      /*
       * pg_identify_object_as_address() returns these as plain "table"/"index",
       * and pg_get_object_address() doesn't recognize "partitioned table" or
       * "partitioned index" at all, so the round-trip is broken.
       */
      UNION SELECT 'partitioned table'
      UNION SELECT 'partitioned index'
    $$
  , 'Verify object_reference.unsupported()'
);
      

SELECT lives_ok(
      command
      , 'prereq: ' || command
    )
  FROM test_prereq
;

SELECT c.* FROM test_object o, test__create(o) c ORDER BY o.seq ASC;

SELECT c.* FROM test_object o, test__register(o) c ORDER BY o.seq DESC; -- Would be nice to randomize...
SELECT c.* FROM test_object o, test__verify(o) c ORDER BY o.seq ASC;

--SET client_min_messages = DEBUG;
SELECT c.* FROM test_object o, test__drop(o) c ORDER BY o.seq DESC;

SELECT is_empty(
  $$SELECT * FROM obj_ref$$
  , 'No object references remain'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2

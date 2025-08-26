\set ECHO none

\i test/load.sql

CREATE TABLE object_group_test_table_1(col1 int, col2 int);
CREATE TABLE object_group_test_table_2(col1 int, col2 int);

CREATE FUNCTION pg_temp.bogus_group(
  command_template text
  , description text
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
BEGIN
RETURN NEXT throws_ok(
  format(command_template, -1)
  , 'P0002'
  , 'object group id -1 does not exist'
  , description || 'for bogus ID throws error'
);
RETURN NEXT throws_ok(
  format(command_template, $$'absurd group name used only for testing purposes ktxbye'$$)
  , 'P0002'
  , 'object group "absurd group name used only for testing purposes ktxbye" does not exist'
  , description || 'for missing group throws error'
);
END
$body$;

SELECT plan(
  0
  +1      -- setup

  +2      -- __create
  +2 + 2  -- __get

  +1 --TODO + 2  -- __object__add

  +3      -- object__getsert with group
  +3      -- Drop tests

  +4      -- __object__remove

  +4 + 2  -- __remove
);

SELECT lives_ok(
  $$CREATE TEMP TABLE test_table_1_id AS SELECT * FROM object_reference.object__getsert('table', 'object_group_test_table_1')$$
  , 'Register test table 1'
);

/*
 * __create
 */
SELECT throws_ok(
  format(
    $$SELECT object_reference.object_group__create(%L)$$
    , repeat('x', 201)
  )
  , '22001'
  , NULL
  , 'object_group__create(...) for group name that is too long throws error'
);
SELECT lives_ok(
  $$SELECT object_reference.object_group__create('Object Reference Test Group')$$
  , $$object_group__create('object reference test group')$$
);

/*
 * __get
 */
SELECT pg_temp.bogus_group(
  $$SELECT object_reference.object_group__get(%s)$$
  , 'object_group__get(...)'
);
SELECT lives_ok(
  $$CREATE TEMP TABLE test_group AS SELECT * FROM object_reference.object_group__get('object reference test group')$$
  , 'Get test group'
);
SELECT is(
  (SELECT object_group_name FROM test_group)
  , 'Object Reference Test Group'
  , 'Verify get returns correct data'
);

-- __object__add
/* TODO
SELECT pg_temp.bogus_group(
  format(
    $$SELECT object_reference.object_group__object__add(%%s, %s)$$
    , (SELECT object__getsert FROM test_table_1_id)
  )
  , 'object_group__object__add(...)'
);
*/
SELECT lives_ok(
  format(
    $$SELECT object_reference.object_group__object__add(%s, %s)$$
    , (SELECT object_group_id FROM test_group)
    , (SELECT object__getsert FROM test_table_1_id)
  )
  , 'object_group__object__add(...) works for test_table_1'
);

-- object__getsert
SELECT throws_ok( -- Can't use helper here
  $$CREATE TEMP TABLE col1_id AS SELECT * FROM object_reference.object__getsert('table column', 'object_group_test_table_1', 'col1', 'absurd group name used only for testing purposes ktxbye')$$
  , 'P0002'
  , 'object group "absurd group name used only for testing purposes ktxbye" does not exist'
  , 'object__getsert with bogus group name'
);
/* TODO
SELECT throws_ok( -- Can't use helper here
  $$CREATE TEMP TABLE col1_id AS SELECT * FROM object_reference.object__getsert_w_group_id('table column', 'object_group_test_table_1', 'col1', -1)$$
  , ''
  , ''
  , 'object__getsert with bogus group id'
);
*/
SELECT lives_ok(
  $$CREATE TEMP TABLE col1_id AS SELECT * FROM object_reference.object__getsert('table column', 'object_group_test_table_1', 'col1', 'object reference test group')$$
  , 'Register test column'
);
SELECT lives_ok(
  $$CREATE TEMP TABLE test_table_2_id AS SELECT * FROM object_reference.object__getsert('table', 'object_group_test_table_2', object_group_name := 'object reference test group')$$
  , 'Register test table 2'
);

-- Drop tests
SELECT throws_ok(
  $$ALTER TABLE object_group_test_table_1 DROP COLUMN col1$$
  , '23503'
  , NULL -- current error is crap anyway
  , 'Dropping col1 fails'
);
SELECT throws_ok(
  $$DROP TABLE object_group_test_table_2$$
  , '23503'
  , NULL -- current error is crap anyway
  , 'Dropping test_table_2 fails'
);
SELECT throws_ok(
  $$SELECT object_reference.object_group__remove('object reference test group')$$
  , '23503'
  , NULL -- current error is crap anyway
  , 'Removing test group fails'
);
SELECT lives_ok(
  $$ALTER TABLE object_group_test_table_1 DROP COLUMN col2$$
  , 'Dropping col2 works'
);

-- __object__remove
SELECT throws_ok( -- Can't use helper here
  format(
    $$SELECT object_reference.object_group__object__remove(%s, %s)$$
    , -1 --(SELECT object_group_id FROM test_group)
    , (SELECT object__getsert FROM test_table_1_id)
  )
  , 'P0002'
  , 'object group id -1 does not exist'
  , '__object__remove() with bogus group throws error)'
);
SELECT throws_ok( -- Can't use helper here
  format(
    $$SELECT object_reference.object_group__object__remove(%s, %s)$$
    , (SELECT object_group_id FROM test_group)
    , -1 --(SELECT object__getsert FROM test_table_1_id)
  )
  , 'P0002'
  , 'object id -1 does not exist'
  , '__object__remove() with bogus object throws error)'
);
SELECT lives_ok(
  format(
    $$SELECT object_reference.object_group__object__remove(%s, %s)$$
    , (SELECT object_group_id FROM test_group)
    , (SELECT object__getsert FROM test_table_1_id)
  )
  , '__object__remove() for test_table_1 works'
);
SELECT throws_ok(
  $$DROP TABLE object_group_test_table_1$$ -- Should not work because column is still registered
  , '23503'
  , NULL -- current error is crap anyway
  , 'Dropping test_table_1 fails'
);

-- __remove
SELECT pg_temp.bogus_group(
  $$SELECT object_reference.object_group__remove(%s)$$
  , 'object_group__object__add(...)'
);
SELECT throws_ok(
  $$SELECT object_reference.object_group__remove('object reference test group')$$
  , '23503'
  , NULL -- current error is crap anyway
  , 'Removing group with items in it fails'
);
SELECT lives_ok(
  format(
    $$SELECT object_reference.object_group__object__remove(%s, %s)$$
    , (SELECT object_group_id FROM test_group)
    , (SELECT object__getsert FROM col1_id)
  )
  , '__object__remove() for col1 works'
);
SELECT lives_ok(
  format(
    $$SELECT object_reference.object_group__object__remove(%s, %s)$$
    , (SELECT object_group_id FROM test_group)
    , (SELECT object__getsert FROM test_table_2_id)
  )
  , '__object__remove() for test_table_2 works'
);
SELECT lives_ok(
  $$SELECT object_reference.object_group__remove('object reference test group')$$
  , 'Removing empty group works'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2

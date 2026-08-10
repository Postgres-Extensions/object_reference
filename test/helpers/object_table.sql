/*
 * NOTE! This intentionally does NOT include testing a schema!
 */

CREATE TABLE test_object(
  seq             serial                      PRIMARY KEY
  , object_type   cat_tools.object_type       NOT NULL
  , object_name   text  NOT NULL
  , secondary     text
  -- NULL means don't create, ~ '^%' means suffix, '' means default, otherwise run as command
  , create_command text
  , drop_command text
);

CREATE TABLE obj_ref(
  seq int NOT NULL UNIQUE REFERENCES test_object
  , object_id int NOT NULL UNIQUE REFERENCES _object_reference.object
);


CREATE FUNCTION test__register(
  o test_object
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_cmd CONSTANT text := format(
    $$INSERT INTO obj_ref VALUES(%s, object_reference.object__getsert(%L, %L, %L))$$
    , o.seq
    , o.object_type
    , o.object_name
    , o.secondary
  );
BEGIN
  RETURN NEXT lives_ok(c_cmd, 'Register: ' || c_cmd);
END
$body$;
CREATE FUNCTION test__verify(
  o test_object
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
BEGIN
  RETURN NEXT is(
    object_reference.object__getsert(o.object_type, o.object_name, o.secondary)
    , (SELECT object_id FROM obj_ref r WHERE r.seq = o.seq)
    , 'Verify getsert returns same ID'
  );
END
$body$;

CREATE FUNCTION test__command_sql(
  o test_object
  , op text
) RETURNS text LANGUAGE plpgsql AS $body$
DECLARE
  cmd CONSTANT text := CASE upper(op)
    WHEN 'ALTER' THEN o.alter_command
    WHEN 'CREATE' THEN o.create_command
    WHEN 'DROP' THEN o.drop_command
    ELSE 'bad'
  END;

  sql text;
BEGIN
  IF cmd = 'bad' THEN
    RAISE 'unknown op "%"', op;
  END IF;

  sql := format(
    '%s %s %s'
    , upper(op)
    , o.object_type
    , o.object_name
  );

  CASE
    WHEN cmd ~ '^%' THEN
      sql := sql || regexp_replace(cmd, '^%', ' ');
      RAISE DEBUG 'sql = %', sql;
    WHEN cmd = '' THEN
      NULL;
    ELSE
      -- cmd could still be NULL
      sql := cmd;
  END CASE;

  RETURN sql;
END
$body$;

CREATE FUNCTION test__create(
  o test_object
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_sql CONSTANT text := test__command_sql(o, 'create');
BEGIN
  IF c_sql IS NULL THEN
    RETURN NEXT pass('No need to ' || op || ' ' || o.object_type);
  ELSE
    RETURN NEXT lives_ok(c_sql, c_sql);
  END IF;
END
$body$;

CREATE FUNCTION test__drop(
  o test_object
  , ref_table text = 'obj_ref'
  , fkey_name name = 'obj_ref_object_id_fkey'
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_sql CONSTANT text := test__command_sql(o, 'drop');

  object_id int;
BEGIN
  SELECT INTO STRICT object_id
      r.object_id
    FROM obj_ref r
    WHERE r.seq = o.seq
  ;
  RETURN NEXT throws_ok(
    c_sql
    , '23503'
    , format(
      'update or delete on table "object" violates foreign key constraint "%s" on table "%s"'
      , fkey_name
      , ref_table
    )
    , 'Drop should fail while reference exists'
  );

  IF ref_table = 'obj_ref' THEN
    DELETE FROM obj_ref WHERE seq = o.seq;
    RETURN NEXT lives_ok(c_sql, c_sql);
  ELSE
    RETURN NEXT skip('ref_table != "obj_ref"');
  END IF;
END
$body$;

CREATE TABLE test_prereq(command text);
INSERT INTO test_prereq VALUES
('CREATE DOMAIN "test domain" int')
, ('CREATE FUNCTION tg_null() RETURNS trigger LANGUAGE plpgsql AS $body$BEGIN RETURN NEW; END$body$')
, ('CREATE TYPE "test type"')
, ($$CREATE FUNCTION "test type in"(cstring) RETURNS "test type" LANGUAGE 'internal' IMMUTABLE AS 'int2in'$$)
, ($$CREATE FUNCTION "test type out"("test type") RETURNS cstring LANGUAGE 'internal' IMMUTABLE AS 'int2in'$$)
;

-- \N is null character
-- sql-lint:disable-block prefer-short-type: COPY payload data, not real type references
COPY test_object(object_type, object_name, secondary, create_command, drop_command) FROM STDIN (DELIMITER '|');
table|test table||%("test column" int)|
index|test table test index||%ON "test table"("test column")|
sequence|test sequence|||
view|test view||%AS SELECT * FROM "test table"|
materialized view|test materialized view||%AS SELECT * FROM "test table"|
table column|test table|second test column|ALTER TABLE "test table" ADD COLUMN "second test column" int|ALTER TABLE "test table" DROP COLUMN "second test column"
domain constraint|test domain|test domain constraint|ALTER DOMAIN "test domain" ADD CONSTRAINT "test domain constraint" CHECK(true)|ALTER DOMAIN "test domain" DROP CONSTRAINT "test domain constraint"
table constraint|test table|test table constraint|ALTER TABLE "test table" ADD CONSTRAINT "test table constraint" CHECK(true)|ALTER TABLE "test table" DROP CONSTRAINT "test table constraint"
function|test function|"test column" int DEFAULT 0|CREATE FUNCTION "test function"("test column" int DEFAULT 0) RETURNS int LANGUAGE sql AS 'SELECT $1'|DROP FUNCTION "test function"(int)
type|test type||CREATE TYPE "test type" (INPUT = "test type in", OUTPUT = "test type out")|DROP TYPE "test type" CASCADE; -- Need to cascade due to functions
cast|test type|integer|CREATE CAST ("test type" AS int4) WITH INOUT|DROP CAST ("test type" AS int4)
default value|test table|test column|ALTER TABLE "test table" ALTER "test column" SET DEFAULT 0|ALTER TABLE "test table" ALTER "test column" DROP DEFAULT
trigger|test table|test trigger|CREATE TRIGGER "test trigger" AFTER INSERT ON "test table" FOR EACH ROW EXECUTE PROCEDURE tg_null()|DROP TRIGGER "test trigger" ON "test table"
\.
-- sql-lint:enable-block

/* EXCLUDED CODE: Not supported
composite type|test complex type||CREATE TYPE "test complex type" AS(r real, i real)|DROP TYPE "test complex type"
view column|test view|test column|\N|\N
materialized view column|test materialized view 2|test materialized view column|CREATE MATERIALIZED VIEW "test materialized view 2" AS SELECT (1,2)::"test complex type" AS "test materialized view column"|DROP MATERIALIZED VIEW "test materialized view 2"
composite type column|test complex type|test attribute|ALTER TYPE "test complex type" ADD ATTRIBUTE "test attribute" real|ALTER TYPE "test complex type" DROP ATTRIBUTE "test attribute"
*/

ALTER TABLE test_object ADD alter_command text;
UPDATE test_object SET alter_command = command
  FROM (VALUES
    ('table column', 'ALTER TABLE "test table" ALTER "test column" SET DEFAULT 1')
    , ('view column', 'ALTER VIEW "test view" ALTER "test column" SET DEFAULT 1')
--    , ('composite type column', 'ALTER TYPE "test complex type" ALTER ATTRIBUTE "test attribute" TYPE float')
    , ('domain constraint', 'ALTER DOMAIN "test domain" RENAME CONSTRAINT "test domain constraint" TO tc; ALTER DOMAIN "test domain" RENAME CONSTRAINT tc TO "test domain constraint"')
    , ('table constraint', 'ALTER TABLE "test table" RENAME CONSTRAINT "test table constraint" TO tc; ALTER TABLE "test table" RENAME CONSTRAINT tc TO "test table constraint"')
    , ('type', 'ALTER TYPE "test type" RENAME TO tt; ALTER TYPE tt RENAME TO "test type"')
  ) v(type, command)
  WHERE object_type = v.type::cat_tools.object_type
;
UPDATE test_object
  SET secondary = nullif(secondary, '')
    , object_name = CASE WHEN object_name ~ '"' THEN object_name ELSE quote_ident(object_name) END
;

-- vi: expandtab sw=2 ts=2

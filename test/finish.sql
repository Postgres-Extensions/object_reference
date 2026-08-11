/*
 * Asserts object_reference's own schemas are absent from the resolved
 * search_path -- checked here (file end, before finish()) rather than only
 * at setup, so a test that mutates search_path mid-file and never restores
 * it is caught. Not foolproof: mutate-then-restore before this line still
 * slips through. \i'd by every SQL file under test/sql (in place of
 * test/pgxntool/finish.sql, which this chains through to).
 *
 * This is the one permanent proof that every reference inside
 * object_reference's own SQL is fully schema-qualified: test/load.sql (via
 * pgxntool's own tap_setup.sql) sets search_path = tap, public for every test
 * file, so object_reference/_object_reference are never on it -- every other
 * test in the suite passing means nothing accidentally relied on
 * search_path to resolve one of the extension's own objects.
 */
SELECT set_hasnt(
    $$ SELECT unnest(current_schemas(false)) $$
  , $$ VALUES ('object_reference') $$
  , 'object_reference schema must not be part of the resolved search_path'
);

SELECT set_hasnt(
    $$ SELECT unnest(current_schemas(false)) $$
  , $$ VALUES ('_object_reference') $$
  , '_object_reference schema must not be part of the resolved search_path'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2

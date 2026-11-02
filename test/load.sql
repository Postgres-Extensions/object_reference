\i test/pgxntool/setup.sql

SET search_path = tap, public;

/*
 * The extension is normally already installed -- committed, once -- by
 * test/install/load.sql before this file ever runs (see that file for the
 * fresh/update/existing mode switch); IF NOT EXISTS makes the statement
 * below a safe no-op in that case. It still does REAL work for
 * test/dump/load_all.sql, which drives its own standalone `createdb` +
 * `psql -f` flow (test/dump/run.sh) entirely outside pg_regress and
 * test/install, and has no other way to get the extension installed.
 */
/*
 * In update and existing modes test/install/load.sql must already have
 * installed the extension; raising here fails every test file when it didn't,
 * instead of letting the CREATE EXTENSION below install the current version
 * fresh and pass.
 */
DO $$
BEGIN
  IF current_setting('object_reference.test_load_mode', true) IN ('update', 'existing')
      AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'object_reference')
  THEN
    RAISE EXCEPTION 'test/install/load.sql did not install object_reference in % mode', current_setting('object_reference.test_load_mode');
  END IF;
END
$$;

SET client_min_messages = WARNING; -- Squelch notices about dependent extensions
CREATE EXTENSION IF NOT EXISTS object_reference CASCADE;
--SET client_min_messages = NOTICE;

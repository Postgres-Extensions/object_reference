\i test/pgxntool/setup.sql

SET search_path = tap, public;

/*
 * In update and existing modes, test/install/load.sql must have left the
 * extension installed at the version under test (test_update_to if set, else
 * default_version). Raising here fails every test file when it did not, which
 * is what makes `make` fail for a load.sql check that stopped short: the
 * CREATE EXTENSION below would otherwise install the current version fresh
 * and pass, and a version left behind would go unnoticed.
 */
DO $$
DECLARE
  v_mode text := current_setting('object_reference.test_load_mode', true);
  v_installed text := (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'object_reference');
  v_expected text;
BEGIN
  IF v_mode IN ('update', 'existing') THEN
    v_expected := coalesce(
      CASE WHEN v_mode = 'update' THEN nullif(current_setting('object_reference.test_update_to', true), '') END
      , (SELECT default_version FROM pg_catalog.pg_available_extensions WHERE name = 'object_reference')
    );
    IF v_installed IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'test/install/load.sql left object_reference at version % in % mode, expected %'
        , coalesce(v_installed, '(not installed)'), v_mode, v_expected;
    END IF;
  END IF;
END
$$;

/*
 * The extension is normally already installed -- committed, once -- by
 * test/install/load.sql before this file ever runs (see that file for the
 * fresh/update/existing mode switch); IF NOT EXISTS makes the statement
 * below a safe no-op in that case. It still does REAL work for
 * test/dump/load_all.sql, which drives its own standalone `createdb` +
 * `psql -f` flow (test/dump/run.sh) entirely outside pg_regress and
 * test/install, and has no other way to get the extension installed.
 */
SET client_min_messages = WARNING; -- Squelch notices about dependent extensions
CREATE EXTENSION IF NOT EXISTS object_reference CASCADE;
--SET client_min_messages = NOTICE;

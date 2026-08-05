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
SET client_min_messages = WARNING; -- Squelch notices about dependent extensions
CREATE EXTENSION IF NOT EXISTS object_reference CASCADE;
--SET client_min_messages = NOTICE;

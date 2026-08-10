\set ECHO none

-- The \'s confuse grep for some reason... :/
\! cat sql/object_reference.sql | grep -v 'echo It will FAIL during pg_dump! ' > test/temp_load.not_sql # TODO: move this to Make after removing clean from testdeps

-- Loads deps, but not extension itself
\i test/pgxntool/setup.sql

CREATE EXTENSION IF NOT EXISTS cat_tools;

CREATE SCHEMA object_reference;

-- Need this so that results are stable across versions (no line #s from ereport messages)
\set VERBOSITY default

/*
 * setup.sql above opened an explicit transaction (see the "TRANSACTION
 * INTENTIONALLY LEFT OPEN!" notice below), so SET LOCAL here reverts when
 * that transaction ends rather than leaking into the rest of the session.
 * Squelches NOTICEs like the %TYPE resolution messages this raw \i load
 * would otherwise spam the test output with -- scoped to this test only,
 * not the shipped extension script itself.
 */
SET LOCAL client_min_messages = WARNING;
\i test/temp_load.not_sql

\echo Loaded OK!
\echo # TRANSACTION INTENTIONALLY LEFT OPEN!

-- vi: expandtab sw=2 ts=2

\set ECHO none

-- The \'s confuse grep for some reason... :/
\! cat sql/object_reference.sql | grep -v 'echo It will FAIL during pg_dump! ' > test/temp_load.not_sql # TODO: move this to Make after removing clean from testdeps

-- Loads deps, but not extension itself
\i test/pgxntool/setup.sql

CREATE EXTENSION IF NOT EXISTS cat_tools;

CREATE SCHEMA object_reference;

-- doesn't work :/ SET client_min_messages = FATAL; -- Need to surpress WARNING or turn down verbosity. Suppressing WARNING seems the better idea...
-- Need to do this instead so that results are stable across versions (no line #s from ereport messages)
\set VERBOSITY default
\i test/temp_load.not_sql

\echo Loaded OK!
\echo # TRANSACTION INTENTIONALLY LEFT OPEN!

-- vi: expandtab sw=2 ts=2

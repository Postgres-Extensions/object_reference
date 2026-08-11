# Committed-once install of the extension (test/install/load.sql), run before
# the main pgTAP suite in its own pg_regress session so its state persists
# (committed) into every per-test file. Must be set (and set to exactly
# "yes"/"no", not auto-detected) BEFORE base.mk is included below, since
# base.mk reads it at parse time.
PGXNTOOL_ENABLE_TEST_INSTALL = yes

# Safeguard for `make results`: refuses to copy test/results/*.out over
# test/expected/*.out while a real regression is showing. This is already
# pgxntool's own default, but set it explicitly so that stays true even if a
# future pgxntool default ever changes.
PGXNTOOL_ENABLE_VERIFY_RESULTS = yes

# TEST_LOAD_SOURCE selects how test/install/load.sql installs the extension:
#   - fresh (default): CREATE EXTENSION object_reference (current version).
#   - update: CREATE EXTENSION at TEST_UPDATE_FROM (default 0.1.0, the only
#     real historical PGXN release) then ALTER EXTENSION UPDATE -- to
#     TEST_UPDATE_TO if set, otherwise to the current default_version
#     ("stable"). Running the SAME suite with the SAME expected output
#     against the updated database verifies it behaves identically to a
#     fresh install.
#   - existing: the extension is ALREADY installed in the target database (by
#     a binary pg_upgrade, or an ALTER EXTENSION UPDATE done outside the
#     suite). load.sql does not touch it; it only asserts presence + current
#     version. Pair with CONTRIB_TESTDB=<db> and
#     EXTRA_REGRESS_OPTS=--use-existing so pg_regress runs against that
#     database instead of dropping and recreating a throwaway one.
#
# The mode (and the update from/to versions) are signalled to load.sql via
# placeholder GUCs. pg_regress does not forward make variables, but the psql
# processes it spawns inherit the environment, so PGOPTIONS reaches load.sql.
#
# The GUCs are exported UNCONDITIONALLY, so load.sql can read them WITHOUT
# missing_ok and fail loudly if they did not propagate. Relying on an absent
# GUC to mean "fresh" is unsafe: a silent break anywhere in the
# make -> PGOPTIONS -> env -> psql chain would quietly run the wrong mode.
#
# TEST_LOAD_SOURCE must be exactly `fresh`, `update` or `existing`; anything
# else is a hard error at parse time (so e.g. `make test
# TEST_LOAD_SOURCE=typo` fails fast rather than defaulting).
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (read by load.sql only in update mode). Empty
# TEST_UPDATE_TO means "update to the current default_version" (stable).
TEST_UPDATE_FROM ?= 0.1.0
TEST_UPDATE_TO ?=

export PGOPTIONS := $(PGOPTIONS) -c object_reference.test_load_mode=$(TEST_LOAD_SOURCE) -c object_reference.test_update_from=$(TEST_UPDATE_FROM) -c object_reference.test_update_to=$(TEST_UPDATE_TO)

# Convenience wrapper: `make test-update` == `make test TEST_LOAD_SOURCE=update`.
# Must recurse (a fresh $(MAKE)) rather than depend on `test`, so the
# parse-time TEST_LOAD_SOURCE conditional above re-evaluates with update set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

include pgxntool/base.mk

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this
testdeps: test_factory

install: cat_tools

# 0.1.0 (TEST_UPDATE_FROM's default -- the update-mode floor, see above) needs
# count_nulls too: its install script's _object_oid.null_count trigger calls
# count_nulls' not_null_count_trigger(), and object_reference.control's
# `requires` (cat_tools only -- count_nulls was dropped once the reg*
# pseudotype removal made that trigger unnecessary) no longer CASCADEs it in.
# Only needed for update-mode testing against that floor -- current
# object_reference has no runtime dependency on count_nulls at all -- so this
# is conditional, not folded into the unconditional `install: cat_tools` above.
ifeq ($(TEST_LOAD_SOURCE),update)
install: count_nulls
endif

.PHONY: count_nulls
count_nulls: $(DESTDIR)$(datadir)/extension/count_nulls.control
$(DESTDIR)$(datadir)/extension/count_nulls.control:
	pgxn install count_nulls

# Clean the cruft pg_regress writes into test/install/ (the self-comparing
# result .out and its diff), which is listed in test/install/.gitignore.
extra_clean += $(addprefix test/install/,$(shell grep -v '^\#' test/install/.gitignore 2>/dev/null))

test: dump_test
extra_clean += $(wildcard test/dump/*.log)
dump_test: test/dump/run.sh test/helpers/object_table.sql $(wildcard test/dump/*.sql)
	$< -f # Force drop of databases if they exist

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	pgxn install --unstable cat_tools

.PHONY: test_factory
test_factory: $(DESTDIR)$(datadir)/extension/test_factory.control
$(DESTDIR)$(datadir)/extension/test_factory.control:
	pgxn install test_factory


# Style linter (see https://github.com/Postgres-Extensions/linter, vendored
# at .vendor/linter -- lint.mk is the thin local hand-off, see its comment).
# Scoped to sql/object_reference.sql rather than the default `sql/ test/`:
# the versioned install/update files under sql/ (object_reference--*.sql,
# e.g. object_reference--0.1.0.sql/--stable.sql) are frozen once released and
# never hand-edited again (see pgxntool's README.asc, "Version-Specific SQL
# Files"), so linting them would produce permanent, unfixable findings and
# make `make lint` unusable as a CI gate.
#
# Guarded on .git being present: a tarball build (PGXN distribution, or any
# `git archive` checkout with no .git) has no submodule to initialize, and
# Make resolves every `include` before running any target regardless of
# which target was requested -- so an unguarded self-init rule in lint.mk
# would break `make`/`make install` entirely for a tarball build, not just
# `make lint`.
ifneq ($(wildcard .git),)
LINT_TARGETS = sql/object_reference.sql test/
include lint.mk
endif

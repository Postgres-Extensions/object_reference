include pgxntool/base.mk

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this
testdeps: test_factory

install: cat_tools count_nulls

test: dump_test
extra_clean += $(wildcard test/dump/*.log)
dump_test: test/dump/run.sh test/helpers/object_table.sql $(wildcard test/dump/*.sql)
	$< -f # Force drop of databases if they exist

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	pgxn install --unstable cat_tools

.PHONY: count_nulls
count_nulls: $(DESTDIR)$(datadir)/extension/count_nulls.control
$(DESTDIR)$(datadir)/extension/count_nulls.control:
	pgxn install --unstable count_nulls

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

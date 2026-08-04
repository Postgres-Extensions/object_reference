include pgxntool/base.mk

testdeps: $(wildcard test/*.sql test/helpers/*.sql) # Be careful not to include directories in this
testdeps: test_factory

install: cat_tools count_nulls

# pgxntool's check-stale-expected target (added in pgxntool 2.2.0) depends on
# installcheck but is listed before install in TEST_DEPS, and Make evaluates a
# target's prerequisites in file-parse order across stanzas -- so plain
# `make test` ran installcheck before install ever happened. Force installcheck
# to require install locally until that's fixed upstream.
installcheck: install

test: dump_test
extra_clean += $(wildcard test/dump/*.log)
dump_test: test/dump/run.sh test/helpers/object_table.sql $(wildcard test/dump/*.sql)
	$< -f # Force drop of databases if they exist

CAT_TOOLS_VERSION = 0.3.0
CAT_TOOLS_BUILD_DIR = tmp/cat_tools-$(CAT_TOOLS_VERSION)
extra_clean += $(CAT_TOOLS_BUILD_DIR)

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	# `pgxn install --unstable cat_tools` resolves to the newest release
	# published to the PGXN package index, which is still 0.2.1 -- it fails
	# standalone on modern PostgreSQL with "column oid specified more than
	# once" at CREATE EXTENSION. A fixed release, 0.3.0, is tagged in
	# cat_tools' own git repo but hasn't been uploaded to PGXN yet, so build
	# it from that tag directly until PGXN has it.
	rm -rf $(CAT_TOOLS_BUILD_DIR)
	git clone --branch $(CAT_TOOLS_VERSION) --depth 1 https://github.com/Postgres-Extensions/cat_tools.git $(CAT_TOOLS_BUILD_DIR)
	$(MAKE) -C $(CAT_TOOLS_BUILD_DIR) install PG_CONFIG=$(PG_CONFIG) DESTDIR=$(DESTDIR)
	rm -rf $(CAT_TOOLS_BUILD_DIR)

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
# never hand-edited again (see this repo's CLAUDE.md / memory), so linting
# them would produce permanent, unfixable findings and make `make lint`
# unusable as a CI gate.
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

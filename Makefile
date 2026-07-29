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


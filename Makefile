TEP_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LIB_DIR   := $(TEP_ROOT)/lib/tep
SPINEL    ?= spinel
TEP       := $(TEP_ROOT)/bin/tep

# Exported so bin/tep injects the right path into the @TEP_SPHTTP_O@
# / @TEP_SQLITE_O@ placeholders inside net.rb / sqlite.rb. Override
# either env var to point at a pre-built .o (useful when the source
# tree isn't writable).
export TEP_SPHTTP_O := $(LIB_DIR)/sphttp.o
export TEP_SQLITE_O := $(LIB_DIR)/tep_sqlite.o
export SPINEL

.PHONY: all clean helper hello sinatra_style bench bench-tep bench-sinatra demo test spinel-fresh

# Always check that the local spinel checkout is on tip-of-master
# before we build / test against it -- spinel moves quickly and a
# stale binary is a fast way to chase ghost regressions. Skip with
# `TEP_SKIP_SPINEL_FRESH=1`; override the spinel location with
# `TEP_SPINEL_DIR`.
spinel-fresh:
	@$(TEP_ROOT)/tools/spinel-fresh.sh

all: spinel-fresh helper hello sinatra_style bench

helper: spinel-fresh $(LIB_DIR)/sphttp.o $(LIB_DIR)/tep_sqlite.o

$(LIB_DIR)/sphttp.o: $(LIB_DIR)/sphttp.c
	cc -O2 -c $< -o $@

$(LIB_DIR)/tep_sqlite.o: $(LIB_DIR)/tep_sqlite.c
	cc -O2 -c $< -o $@

hello: helper
	$(TEP) build examples/hello.rb

sinatra_style: helper
	$(TEP) build examples/sinatra_style.rb

bench: bench-tep

bench-tep: helper
	$(TEP) build bench/hello_bench.rb
	$(TEP) build bench/api_bench.rb

bench-sinatra:
	cd bench && bundle _2.7.2_ install --quiet

demo: hello
	./examples/hello

test: helper
	@pkill -f tep-test 2>/dev/null; true
	ruby test/run_all.rb

clean:
	rm -f $(LIB_DIR)/*.o
	rm -f examples/hello examples/sinatra_style examples/diag
	rm -f examples/.*.tep.rb
	rm -f bench/hello_bench bench/api_bench bench/.*.tep.rb
	rm -f test/real_world/.*.tep.rb
	# Compiled binaries in test/real_world/ have no extension; sources
	# are .rb. Find executables and remove only those.
	@find test/real_world -maxdepth 1 -type f -perm -u+x ! -name '*.rb' -delete 2>/dev/null || true

TEP_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LIB_DIR   := $(TEP_ROOT)/lib/tep
SPINEL    ?= spinel
TEP       := $(TEP_ROOT)/bin/tep

# Exported so bin/tep injects the right path into the @TEP_SPHTTP_O@
# / @TEP_SQLITE_O@ / @TEP_PG_O@ placeholders inside net.rb / sqlite.rb /
# pg.rb. Override either env var to point at a pre-built .o (useful
# when the source tree isn't writable). Crypto symbols (sp_crypto_*)
# live in spinel's libspinel_rt.a since matz/spinel#514, no separate
# .o needed.
export TEP_SPHTTP_O := $(LIB_DIR)/sphttp.o
export TEP_SQLITE_O := $(LIB_DIR)/tep_sqlite.o
export TEP_PG_O     := $(LIB_DIR)/tep_pg.o
export SPINEL

# libpq cflags / libs. pkg-config is the preferred path (libpq ships
# a .pc file on Linux + Homebrew); pg_config is the fallback for
# stripped-down hosts.
#
# NB: `pg_config --cflags` returns the cflags PostgreSQL itself was
# built with (warning flags, -O2, ...), NOT the cflags a libpq
# CONSUMER needs. We want -I<includedir>; the consumer cflags are
# constructed from `pg_config --includedir`. Same for -L from
# `--libdir`. If neither lookup finds libpq, both vars stay empty
# and the compile fails at link time with "cannot find -lpq" --
# the right loud failure for "you wanted Tep::PG but didn't install
# libpq".
TEP_PG_CFLAGS ?= $(shell \
    pkg-config --cflags libpq 2>/dev/null || \
    pg_config --includedir 2>/dev/null | sed -e 's|^|-I|')
TEP_PG_LIBS   ?= $(shell \
    pkg-config --libs libpq 2>/dev/null || \
    (pg_config --libdir 2>/dev/null | sed -e 's|^|-L|' ; echo "-lpq") | tr '\n' ' ')
export TEP_PG_CFLAGS TEP_PG_LIBS

.PHONY: all clean helper hello sinatra_style bench bench-tep bench-sinatra demo test test-parallel spinel-fresh test-pg vendor-examples vendor-spinelkit doctor

# Re-sync the vendored SpinelKit lib (lib/spinel_kit/, sig/spinel_kit/) from the
# upstream checkout. spinel_kit is a published gem; tep depends on its JSON codec
# + logger. INTERIM vendoring (committed under lib/ so it travels with tep) until
# spinel-compat gains transitive gem->gem vendoring -- OriPekelman/spinelgems#19.
# Override the source with SPINELKIT_DIR. See tools/vendor-spinelkit.sh.
vendor-spinelkit:
	@$(TEP_ROOT)/tools/vendor-spinelkit.sh

# Vendor each gem example's Gemfile-declared dependencies via
# bundler-spinel (spinel-compat vendor, from $(SPINELGEMS)) into
# examples/<x>/vendor/spinel -- where bin/tep follows the generated
# deps.rb. This is how a tep app uses a real published gem: declare it in
# a Gemfile, let spinelgems resolve + place it, require_relative the
# deps. Run inside the dev container (mounts /spinelgems, sets SPINELGEMS)
# or point SPINELGEMS at a spinelgems checkout. Regenerated from the
# committed Gemfile.lock; the output is gitignored.
SPINELGEMS ?= ../spinelgems
vendor-examples:
	@for d in examples/*/; do \
	  [ -f "$$d/Gemfile.lock" ] || continue; \
	  echo "vendor: $$d"; \
	  ( cd "$$d" && ruby -I "$(SPINELGEMS)/lib" "$(SPINELGEMS)/exe/spinel-compat" vendor ) || exit 1; \
	done

# Always check that the local spinel checkout is on tip-of-master
# before we build / test against it -- spinel moves quickly and a
# stale binary is a fast way to chase ghost regressions. Skip with
# `TEP_SKIP_SPINEL_FRESH=1`; override the spinel location with
# `TEP_SPINEL_DIR`.
spinel-fresh:
	@$(TEP_ROOT)/tools/spinel-fresh.sh

all: spinel-fresh helper hello sinatra_style bench

helper: spinel-fresh $(LIB_DIR)/sphttp.o $(LIB_DIR)/tep_sqlite.o $(LIB_DIR)/tep_pg.o

$(LIB_DIR)/sphttp.o: $(LIB_DIR)/sphttp.c
	cc -O2 -c $< -o $@

$(LIB_DIR)/tep_sqlite.o: $(LIB_DIR)/tep_sqlite.c
	cc -O2 -c $< -o $@

$(LIB_DIR)/tep_pg.o: $(LIB_DIR)/tep_pg.c
	cc -O2 -c $(TEP_PG_CFLAGS) $< -o $@

hello: helper
	$(TEP) build examples/hello.rb

sinatra_style: helper
	$(TEP) build examples/sinatra_style.rb

bench: bench-tep

bench-tep: helper
	$(TEP) build bench/hello_bench.rb
	$(TEP) build bench/api_bench.rb
	$(TEP) build bench/pg_bench.rb

bench-sinatra:
	cd bench && bundle _2.7.2_ install --quiet

demo: hello
	./examples/hello

test: helper
	@pkill -f tep-test 2>/dev/null; true
	ruby test/run_all.rb

# `make doctor` -- OPTIONAL, DEV-ONLY inference health check via
# spinel-dev's `doctor` (compile-probe + emit-rbs untyped scan +
# value-bisect). Runs on the inlined .tep.rb of a couple of examples
# (tep apps are FFI, so --no-cruby single-sided). NOT a prerequisite of
# `all`/`test`/CI -- it self-skips when ../spinel-dev is absent, so tep
# never gains a hard dependency on the tooling. Run `make all` first to
# produce the .tep.rb. Override the tool path with DOCTOR=.
DOCTOR ?= ../spinel-dev/tools/doctor/doctor.sh
doctor:
	@if [ ! -x "$(DOCTOR)" ]; then \
	  echo "make doctor: spinel-dev not found at $(DOCTOR) (optional dev tooling); skipping."; \
	else \
	  for tep in examples/.hello.tep.rb examples/.sinatra_style.tep.rb; do \
	    if [ -f "$$tep" ]; then \
	      echo "== doctor $$tep =="; \
	      SPINEL_DIR="$${SPINEL_DIR:-$$HOME/sites/spinel}" "$(DOCTOR)" --no-cruby "$$tep" || true; \
	    else \
	      echo "make doctor: $$tep not built (run \`make all\`); skipping it."; \
	    fi; \
	  done; \
	fi

# `make test-parallel` -- dev fast loop. Runs each test/test_*.rb in
# its own process in parallel (sidestepping the harness's "one thread
# per class" constraint), with per-process port-base allocation. Cuts
# wall time roughly by core count on the gx10 (~13min serial ->
# ~1-2min). `make test` stays serial -- the canonical / CI path with
# clean output ordering. Cap with TEP_TEST_PROCS=N.
test-parallel: helper
	@pkill -f tep-test 2>/dev/null; true
	ruby test/run_parallel.rb

# `make test-pg` -- runs test/test_pg.rb against a real PostgreSQL.
# Reads PG_TEST_URL from the environment if set; otherwise expects
# the caller to have a PG reachable at the default libpq path.
# Without PG_TEST_URL the test class skips cleanly (so `make test`
# is unaffected by Postgres availability).
#
# Recipe to spin up a throwaway PG via docker:
#
#   docker run -d --rm --name tep_test_pg -p 54329:5432 \
#     -e POSTGRES_PASSWORD=postgres postgres:16
#   until docker exec tep_test_pg pg_isready -U postgres | grep -q accepting; do sleep 1; done
#   PG_TEST_URL='postgresql://postgres:postgres@127.0.0.1:54329/postgres' make test-pg
#   docker stop tep_test_pg
test-pg: helper
	@pkill -f tep-test 2>/dev/null; true
	ruby test/test_pg.rb

clean:
	rm -f $(LIB_DIR)/*.o
	rm -f examples/hello examples/sinatra_style examples/diag
	rm -f examples/.*.tep.rb
	rm -f bench/hello_bench bench/api_bench bench/.*.tep.rb
	rm -f test/real_world/.*.tep.rb
	# Compiled binaries in test/real_world/ have no extension; sources
	# are .rb. Find executables and remove only those.
	@find test/real_world -maxdepth 1 -type f -perm -u+x ! -name '*.rb' -delete 2>/dev/null || true

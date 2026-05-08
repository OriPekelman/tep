TEP_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LIB_DIR   := $(TEP_ROOT)/lib/tep
SPINEL    ?= spinel
TEP       := $(TEP_ROOT)/bin/tep

# Exported so bin/tep injects the right path into net.rb's @TEP_SPHTTP_O@
# placeholder. Override TEP_SPHTTP_O in env to point at a pre-built .o
# (useful when the source tree isn't writable).
export TEP_SPHTTP_O := $(LIB_DIR)/sphttp.o
export SPINEL

.PHONY: all clean helper hello sinatra_style bench bench-tep bench-sinatra demo test

all: helper hello sinatra_style bench

helper: $(LIB_DIR)/sphttp.o

$(LIB_DIR)/sphttp.o: $(LIB_DIR)/sphttp.c
	cc -O2 -c $< -o $@

hello: helper
	$(TEP) build examples/hello.rb

sinatra_style: helper
	$(TEP) build examples/sinatra_style.rb

bench: bench-tep

bench-tep: helper
	$(TEP) build bench/hello_bench.rb

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
	rm -f bench/hello_bench bench/.*.tep.rb
	rm -f test/real_world/.*.tep.rb
	# Compiled binaries in test/real_world/ have no extension; sources
	# are .rb. Find executables and remove only those.
	@find test/real_world -maxdepth 1 -type f -perm -u+x ! -name '*.rb' -delete 2>/dev/null || true

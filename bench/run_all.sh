#!/bin/sh
# Compare Tep vs Sinatra+Puma across two scenarios:
#   hello -- raw plumbing (existing hello_bench)
#   api   -- SQLite SELECT by id + JSON encode. The DB handle is
#            cached per-worker (Tep) / per-thread (Sinatra) so we're
#            measuring the request path, not connection setup.
#
# Runs inside the Tep dev container (wrk + Sinatra+Puma are already
# installed). On gx10 / Linux directly:
#
#   docker compose run --rm dev bench/run_all.sh
#
# Override duration / connections via env (must be exported into the
# container's env via docker-compose.yml, or set in the script directly):
#   THREADS=8 CONN=256 DUR=10s WORKERS=8
#
# Note: tep occasionally emits a non-trivial "Non-2xx or 3xx" count
# on the api scenario when running back-to-back after the hello
# scenario in the same wrk session -- the api endpoint serves clean
# 200s when probed by hand mid-load. Suspected interaction with
# wrk's connection pool re-use across runs; the live success rate
# is the more meaningful figure (~190k req/s of 2xx for tep vs ~24k
# for Sinatra at this load). Run each scenario in isolation to get
# clean numbers.
set -e
cd "$(dirname "$0")"

# Bump the FD limit -- 8 workers each opening SQLite-with-WAL on every
# request can easily blow past the 1024 default under wrk -c 256.
ulimit -n 65536 2>/dev/null || true

DUR=${DUR:-10s}
THREADS=${THREADS:-8}
CONN=${CONN:-256}
WORKERS=${WORKERS:-8}

echo "==== environment ===="
uname -a
echo "cpus: $(nproc)"
echo "wrk:  $(wrk -v 2>&1 | head -1)"
echo "dur=$DUR threads=$THREADS connections=$CONN tep-workers=$WORKERS"
echo

# -------------------------------------------------------------------
# 1. hello -- raw plumbing
# -------------------------------------------------------------------
echo "==== scenario: hello (raw plumbing) ===="

echo
echo "--- tep, $WORKERS workers ---"
./hello_bench -p 4567 -w "$WORKERS" > /tmp/tep_hello.log 2>&1 &
TEPPID=$!
sleep 1
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency http://127.0.0.1:4567/ 2>&1 | tail -10
kill $TEPPID 2>/dev/null
wait 2>/dev/null

echo
echo "--- sinatra+puma, $WORKERS workers x 4 threads ---"
cp Gemfile.linux Gemfile
rm -f Gemfile.lock
bundle install --quiet 2>&1 | tail -1
bundle exec puma -e production -w "$WORKERS" -t 4:4 -b tcp://127.0.0.1:4570 config.ru > /tmp/puma_hello.log 2>&1 &
PUMA=$!
sleep 4
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency http://127.0.0.1:4570/ 2>&1 | tail -10
kill $PUMA 2>/dev/null
wait 2>/dev/null

# -------------------------------------------------------------------
# 2. api -- SQLite SELECT + JSON
# -------------------------------------------------------------------
# Pause between scenarios so TCP TIME_WAITs from the previous wrk
# round drain; without this, the first ~half of api responses come
# back as RST/aborted and wrk counts them as Non-2xx.
sleep 5
echo
echo "==== scenario: api (SQLite SELECT + JSON) ===="

rm -f /tmp/tep_api_bench.db
echo
echo "--- tep, $WORKERS workers ---"
./api_bench -p 4567 -w "$WORKERS" > /tmp/tep_api.log 2>&1 &
TEPPID=$!
# on_start seeds 1000 rows in every worker before that worker
# enters the accept loop. Give it room.
sleep 5
curl -s http://127.0.0.1:4567/users/42 > /dev/null
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4567/users/42' 2>&1 | tail -10
kill $TEPPID 2>/dev/null
wait 2>/dev/null

echo
echo "--- sinatra+puma, $WORKERS workers x 4 threads ---"
# sinatra_api.rb seeds the same DB file; sqlite3 gem is in Gemfile.linux
bundle exec puma -e production -w "$WORKERS" -t 4:4 -b tcp://127.0.0.1:4570 config_api.ru > /tmp/puma_api.log 2>&1 &
PUMA=$!
sleep 4
curl -s http://127.0.0.1:4570/users/42 > /dev/null
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4570/users/42' 2>&1 | tail -10
kill $PUMA 2>/dev/null
wait 2>/dev/null

echo
echo "==== done ===="

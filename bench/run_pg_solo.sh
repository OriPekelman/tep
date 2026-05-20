#!/bin/sh
# Re-run the PG scenario in isolation. Pattern mirrors
# bench/run_api_solo.sh (SQLite); the difference is the storage
# backend.
#
# Expects PG_URL in the environment, defaulting to
# postgresql:///postgres if unset. The docker-compose `pg` service
# is the canonical local target:
#
#   docker compose up -d pg
#   PG_URL='postgresql://postgres:postgres@pg/postgres' \
#     bench/run_pg_solo.sh
#
# Or against a host PG (assumes libpq client is reachable):
#
#   PG_URL='postgresql://user:pw@127.0.0.1:5432/dbname' \
#     bench/run_pg_solo.sh
set -e
cd "$(dirname "$0")"

ulimit -n 65536 2>/dev/null || true

DUR=${DUR:-10s}
THREADS=${THREADS:-8}
CONN=${CONN:-256}
WORKERS=${WORKERS:-8}
PG_URL=${PG_URL:-"postgresql:///postgres"}
export PG_URL

echo "==== environment ===="
uname -a
echo "cpus: $(nproc 2>/dev/null || echo '?')"
echo "wrk:  $(wrk -v 2>&1 | head -1)"
echo "pg:   $PG_URL"
echo "dur=$DUR threads=$THREADS connections=$CONN workers=$WORKERS"
echo

echo "==== tep pg (solo) ===="
./pg_bench -p 4567 -w "$WORKERS" > /tmp/tep_pg_solo_srv.log 2>&1 &
PID=$!
sleep 5
curl -s http://127.0.0.1:4567/users/42; echo
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4567/users/42' 2>&1 | tail -12
kill $PID 2>/dev/null
wait 2>/dev/null

sleep 5

echo
echo "==== sinatra pg (solo) ===="
cp Gemfile.linux Gemfile
rm -f Gemfile.lock
bundle install --quiet 2>&1 | tail -1
bundle exec puma -e production -w "$WORKERS" -t 4:4 -b tcp://127.0.0.1:4570 config_pg.ru > /tmp/puma_pg_solo.log 2>&1 &
PUMA=$!
sleep 4
curl -s http://127.0.0.1:4570/users/42; echo
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4570/users/42' 2>&1 | tail -12
kill $PUMA 2>/dev/null
wait 2>/dev/null

echo
echo "==== done ===="

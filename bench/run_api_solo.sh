#!/bin/sh
# Re-run the api scenario in isolation. The back-to-back form in
# run_all.sh poisons tep's 2xx count because of TIME_WAIT pressure
# from the prior hello scenario; this script avoids that.
set -e
cd "$(dirname "$0")"

ulimit -n 65536 2>/dev/null || true

DUR=${DUR:-10s}
THREADS=${THREADS:-8}
CONN=${CONN:-256}
WORKERS=${WORKERS:-8}

echo "==== tep api (solo) ===="
rm -f /tmp/tep_api_bench.db
./api_bench -p 4567 -w "$WORKERS" > /tmp/tep_api_solo_srv.log 2>&1 &
PID=$!
sleep 5
curl -s http://127.0.0.1:4567/users/42; echo
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4567/users/42' 2>&1 | tail -12
kill $PID 2>/dev/null
wait 2>/dev/null

sleep 5

echo
echo "==== sinatra api (solo) ===="
cp Gemfile.linux Gemfile
rm -f Gemfile.lock
bundle install --quiet 2>&1 | tail -1
bundle exec puma -e production -w "$WORKERS" -t 4:4 -b tcp://127.0.0.1:4570 config_api.ru > /tmp/puma_api_solo.log 2>&1 &
PUMA=$!
sleep 4
curl -s http://127.0.0.1:4570/users/42; echo
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency 'http://127.0.0.1:4570/users/42' 2>&1 | tail -12
kill $PUMA 2>/dev/null
wait 2>/dev/null

echo
echo "==== done ===="

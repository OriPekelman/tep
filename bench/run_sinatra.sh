#!/bin/sh
set -e
cd /workspace/bench
cp Gemfile.linux Gemfile
rm -f Gemfile.lock
bundle install --quiet 2>&1 | tail -3
echo "=== sinatra+puma+CRuby (Linux/aarch64) ==="
bundle exec puma -e production -w 8 -t 4:4 -b tcp://127.0.0.1:4570 config.ru > /tmp/puma.log 2>&1 &
SVPID=$!
sleep 4
wrk -t8 -c256 -d10s --latency http://127.0.0.1:4570/ 2>&1 | tail -12
kill $SVPID 2>/dev/null

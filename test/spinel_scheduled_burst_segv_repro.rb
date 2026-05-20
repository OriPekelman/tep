# Minimal repro for the Tep::Server::Scheduled segfault under
# concurrent HTTP/1.1 keep-alive bursts. Stand-alone -- doesn't
# require PG or any other battery; the segfault reproduces with
# the plainest possible "hello world" route.
#
# Build + run:
#   bin/tep build test/spinel_scheduled_burst_segv_repro.rb -o /tmp/repro
#   /tmp/repro -p 4985 &
#   # Drive it with two concurrent persistent-keepalive clients:
#   ruby -e '
#     require "net/http"; require "uri"
#     uri = URI("http://127.0.0.1:4985/hi")
#     2.times.map { Thread.new {
#       Net::HTTP.start(uri.host, uri.port) { |h|
#         100.times { h.request(Net::HTTP::Get.new(uri.path)) }
#       }
#     } }.each(&:join)
#   '
#
# Observed (spinel master 6513d2d, 2026-05-20): server dies with
# SIGSEGV (SEGV_ACCERR) somewhere around request ~60-80. strace
# shows the segfault happens right after a normal-looking recvfrom
# returns the HTTP request bytes -- the crash is in the Ruby /
# spinel runtime between recv and the handler dispatch + write.
#
# Default Tep::Server (prefork-blocking) handles the same burst
# fine; the segfault is specific to Tep::Server::Scheduled.
require_relative "../lib/tep"
set :scheduler, :scheduled

get '/hi' do
  "hello"
end

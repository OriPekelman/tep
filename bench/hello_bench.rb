# Minimal handler for benching tep itself -- no filters, no static,
# just a single fixed-string response. We let CLI args drive port and
# worker count so the same binary can run single-worker and prefork.
require_relative "../lib/tep"

class Hello < Tep::Handler
  def handle(req, res)
    res.headers["Content-Type"] = "text/plain"
    "hello, world\n"
  end
end

Tep.get "/", Hello.new

port    = 4567
workers = 1
i = 0
while i < ARGV.length
  if ARGV[i] == "-p"
    port = ARGV[i + 1].to_i
    i += 2
  elsif ARGV[i] == "-w"
    workers = ARGV[i + 1].to_i
    i += 2
  else
    i += 1
  end
end

Tep.run!(port, workers, false)

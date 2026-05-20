# macOS concurrency on tep — current gap and the path forward

Status: design plan, pre-implementation. Captures the macOS-specific
divergence in tep's prefork model and sketches the cooperative
concurrency path that closes it.

## Background — the SO_REUSEPORT gap

Tep's default server (`Tep::Server`) is prefork: one parent listens
on `bind(port)`, forks N workers, each worker calls `accept()` in a
blocking loop. To distribute incoming connections evenly the kernel
relies on `SO_REUSEPORT` — each worker binds the SAME port with the
flag set, and the kernel pairs incoming SYN packets to one of the
listening sockets.

- **Linux 3.9+**: `SO_REUSEPORT` load-balances new connections across
  all binders by 4-tuple hash. The result is roughly even
  distribution across the pool.
- **Darwin (macOS / BSD)**: `SO_REUSEPORT` permits multiple binds on
  the same port but does **not** load-balance. New connections land
  on whichever worker called `accept()` most recently. Under load
  the pool collapses to a single hot worker.

In practice this means: any tep app that does outbound HTTP from
inside a handler — calling back to itself, calling a sibling service
that's slow, anything that holds the worker fiber across an I/O wait
— starves the listener on macOS. `test/test_http.rb`'s
`/selfcall/:port` route is the canonical demo:

```ruby
get '/selfcall/:port' do
  r = Tep::Http.get("http://127.0.0.1:" + params[:port] + "/ping")
  ...
end
```

- **Linux**: outer handler runs on worker A; outer's outbound TCP
  connect lands on worker B (different 4-tuple hash); B returns
  pong; A completes. 5ms round-trip.
- **macOS**: outer handler runs on worker A; outer's outbound TCP
  connect lands on worker A (only worker servicing this port at
  this instant); A is blocked in the outer handler waiting for
  inner response; deadlock; `Net::ReadTimeout` after the client's
  patience runs out.

Documented in `README.md`'s macOS note. Currently `test/test_http.rb`
sees a ~5-test cluster of `Net::ReadTimeout` errors on macOS for
exactly this reason.

## What "set :workers, 1" alone does NOT fix

Reducing to a single worker doesn't help — that worker still
serializes everything. With one worker:

1. Outer GET /selfcall/:port arrives → worker dispatches the handler.
2. Handler calls Tep::Http.get → opens TCP socket → kernel queues
   the connect in the listen backlog (worker hasn't returned to
   accept yet).
3. Tep::Http sends the request via `send(2)`; data sits in the
   kernel's socket buffer.
4. Tep::Http does `recv(2)` — blocks. Worker is busy in `recv`.
5. No one calls `accept(2)` to handle the queued connect. The
   socket buffer can't fill because no one's reading it. Deadlock,
   same as N=4-on-Mac.

So **single-worker doesn't avoid the deadlock**; it makes the
deadlock instant and guaranteed instead of probabilistic. It does
sidestep the SO_REUSEPORT load-balancing question, which matters for
non-self-calling apps — but the same Linux + Mac asymmetry
disappears under `workers=1` because there's no pool to distribute.

For tep apps that don't self-call, `workers=1` on macOS is perfectly
fine; that's the cheap-cost case the per-platform conditional below
covers. For apps that DO self-call (which the TestHttp suite stresses
deliberately), the only path that works on macOS is **cooperative
concurrency**.

## Path forward — cooperative I/O via Tep::Server::Scheduled

`Tep::Server::Scheduled` (shipped in v0.5 for the WebSocket battery)
runs one fiber per connection inside one worker process, parking on
`Tep::Scheduler.io_wait(fd, mode, timeout)` for any blocking I/O.
N concurrent connections multiplex through M >> N fibers; the worker
process never blocks userland. Linux + Mac semantics converge —
neither relies on SO_REUSEPORT distribution because there is no pool.

What's missing: **`Tep::Http` is currently synchronous and prefork-
shaped**. `sphttp_recv_all` is a blocking `recv()` loop with no
yield to the scheduler. So an `:scheduler, :scheduled` app whose
handler calls `Tep::Http.get` still pegs the worker fiber on the
recv call — accept fiber can't run, no inner connection is accepted,
deadlock.

The right shape is a cooperative `Tep::Http` that, when running
under the scheduled server, uses `Tep::Scheduler.io_wait(fd, READ)`
between each recv. The bones already exist:

- `sphttp_recv_some(fd, maxlen)` is non-blocking when fd is in
  non-blocking mode.
- `Sock.sphttp_set_nonblock(fd)` toggles the flag.
- `Tep::Scheduler.io_wait(fd, READ, timeout_seconds)` parks the
  current fiber until the fd has data or the timeout elapses;
  outside a scheduled context it falls back to a single-shot poll
  so callers don't need to branch.

## Phased plan

### Phase 1 — runtime-detected cooperative `Tep::Http` (shipped)

`Tep::Http.send_req` now checks `Tep::Scheduler.scheduled_context?`
and routes through `send_req_coop` when running inside a scheduled
fiber; otherwise it falls through to `send_req_blocking` (the
original `sphttp_recv_all` path). Same public API — Sinatra-shaped
apps don't have to think about which server is underneath.

```ruby
def self.send_req(verb, url, body, headers)
  if Tep::Scheduler.scheduled_context?
    Http.send_req_coop(verb, url, body, headers)
  else
    Http.send_req_blocking(verb, url, body, headers)
  end
end
```

`send_req_coop` mirrors the wire shape exactly, but after
`sphttp_connect` it flips the fd to non-blocking and replaces the
synchronous `sphttp_recv_all` with a `Tep::Scheduler.io_wait(fd, READ)`
+ `sphttp_recv_some` loop. While the outer fiber is parked here,
the accept fiber on the same worker can run, accept the inner
connection, and dispatch its handler — which is the only shape that
unblocks the macOS self-call deadlock.

Scope shipped alongside Phase 1:

- `Tep::Scheduler.scheduled_context?` predicate (true when a fiber
  is currently running under tick()).
- A scheduler latency fix in `Tep::Scheduler.tick`: when any fiber
  is already time-due (wake_at <= now), poll(2)'s timeout collapses
  to 0 instead of blocking for the caller's `poll_timeout_ms`.
  Without this, each `pause(0)` handoff between fibers cost a full
  poll-timeout's worth of wall time — 1s on the default
  `Tep::Server::Scheduled` tick — which would have made the
  cooperative round-trip *correct* but ~3s slower than the
  blocking path it replaces.

### Phase 2 — accept-loop in the cooperative path

Already done. `Tep::Server::Scheduled.accept_loop` parks on
`io_wait(sfd, READ, -1)` and spawns one fiber per accepted
connection. The pieces are in `lib/tep/server_scheduled.rb`.

### Phase 3 — opt-in for TestHttp (shipped)

With (1) and (2) in place, `test/test_http.rb` declares:

```ruby
set :scheduler, :scheduled
set :workers, 1
```

— and the self-call tests work end-to-end on Linux AND macOS. No
SO_REUSEPORT magic, no per-platform skips. The 5 darwin `skip` calls
that previously guarded the cluster have been removed.

### Phase 4 — flip the default

Once cooperative `Tep::Http` is well-tested, consider making
`Tep::Server::Scheduled` the tep default (replacing `Tep::Server`).
The prefork model is a Linux-specific performance optimisation;
the cooperative model is the more portable + composable shape, and
the WebSocket battery already requires it.

The rollout is a separate doc — `Tep::Server::Blocking` (the
prefork) stays as a v0.6-deprecated option for one minor cycle, then
gets deleted.

## Why now (or not)

Tep's primary deployment target is Linux. The macOS divergence
matters for **developer ergonomics on Mac** (the dev machine for
most tep users) but not for production behavior. The fix is worth
shipping because:

- Tep's docs claim "runs on macOS" — a 5-test failure on `make test`
  is a poor first impression.
- The Phase 1 work (cooperative Tep::Http) is also a real
  improvement under Tep::Server::Scheduled on Linux — slow upstream
  calls no longer block a worker fiber for the duration.
- It's the natural next step after the WebSocket battery (which
  already requires Scheduled).

Estimated cost: ~2-3 days for Phase 1 + the runtime-detect glue;
Phase 3 (test skips + opt-in) is mechanical, hours not days.

## References

- `README.md` macOS note (the brief, user-facing version).
- `lib/tep/server_scheduled.rb` — the cooperative server.
- `lib/tep/scheduler.rb` — `Tep::Scheduler.io_wait` lives here.
- `lib/tep/http.rb` — the current blocking Tep::Http; the file to
  grow the cooperative path on top of.
- `test/test_http.rb` — the self-call test cluster the per-platform
  conditional applies to.
- Apple developer docs on SO_REUSEPORT semantics:
  <https://developer.apple.com/forums/thread/736107> (the kernel
  team's confirmation that load-balancing is intentional Linux-only).

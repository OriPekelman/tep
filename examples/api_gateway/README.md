# api_gateway — a capability-gated API gateway on `Tep::Proxy`

The non-streaming sibling of [`examples/llm_gateway`](../llm_gateway).
Fronts an upstream HTTP API on the buffered (6.1) proxy path and adds
the three jobs of a gateway in ~30 lines:

1. **Authorization** — `before` short-circuits with `403` unless
   `req.identity.may?(:call_upstream)`. The upstream is never hit for
   a denied request.
2. **Credential swap** — for an authorized request, strip the
   client's key and attach the server-side one (`ureq.set_header`).
3. **Observability** — `after` logs the call and stamps
   `X-Proxy-Status` / `X-Proxy-Upstream` on the response — **including
   for rejected requests** (`after` runs on the short-circuit path
   too, so the audit log sees denials).

Uses the **block-form proxy DSL** (`api.before do … end`), which
`bin/tep` lowers to a `Tep::Proxy` subclass.

## Run

```sh
UPSTREAM=https://api.example.com \
UPSTREAM_KEY=secret \
GATEWAY_KEY=let-me-in \
  bin/tep build examples/api_gateway/app.rb -o /tmp/ag && /tmp/ag -p 4567

curl -i localhost:4567/v1/data                          # 403, missing capability
curl -i localhost:4567/v1/data -H 'x-api-key: let-me-in'  # forwarded with upstream key
```

Both responses carry `X-Proxy-Status` / `X-Proxy-Upstream`.

## Notes

- The `before do … end` filter granting `:call_upstream` on the
  gateway key is a **stand-in** for the Auth battery — a real app
  installs `Tep::Auth` (bearer JWT / session / OAuth2), which
  populates `req.identity` the same way, so the `may?` gate is
  unchanged.
- One `Tep::Proxy` instance serves many routes; mount whatever paths
  you proxy.
- Non-streaming (buffered) — for SSE/streaming upstreams + per-request
  telemetry, see `examples/llm_gateway`.

## See also

- [`docs/PROXY-BATTERY.md`](../../docs/PROXY-BATTERY.md) — the battery.
- [`examples/llm_gateway`](../llm_gateway) — the streaming half of 6.3.

# examples/api_gateway -- a capability-gated API gateway on Tep::Proxy.
#
# The non-streaming sibling of examples/llm_gateway. Fronts an upstream
# HTTP API and adds the three things a gateway exists for, on the
# buffered (6.1) proxy path:
#
#   1. Authorization  -- gate on req.identity.may?(:call_upstream);
#                        reject (403) before the upstream is ever hit.
#   2. Credential swap -- strip the client's key, attach the server's.
#   3. Observability   -- log + stamp X-Proxy-* headers on the way out,
#                         including for rejected requests (audit).
#
# Run:
#   UPSTREAM=https://api.example.com UPSTREAM_KEY=secret \
#   GATEWAY_KEY=let-me-in \
#     bin/tep build examples/api_gateway/app.rb -o /tmp/ag && /tmp/ag -p 4567
#
#   curl -i localhost:4567/v1/data                       # 403 (no key)
#   curl -i localhost:4567/v1/data -H 'x-api-key: let-me-in'   # forwarded
require 'sinatra'

UPSTREAM     = ENV["UPSTREAM"]     || "http://127.0.0.1:8080"
UPSTREAM_KEY = ENV["UPSTREAM_KEY"] || ""
GATEWAY_KEY  = ENV["GATEWAY_KEY"]  || "let-me-in"
LOGGER       = SpinelKit::Log.new   # stderr; .to_file(path) to redirect

# Stand-in for the Auth battery: grant :call_upstream to callers
# presenting the gateway key. A real app installs Tep::Auth (bearer
# JWT / session / OAuth2), which populates req.identity the same way.
before do
  if req.req_headers["x-api-key"] == GATEWAY_KEY
    req.identity = Tep::Identity.new("client:demo", nil, [:call_upstream])
  end
end

api = Tep::Proxy.new(UPSTREAM)

# Capability gate + credential swap. Returning true short-circuits --
# the upstream is never called; res (set here) goes straight back.
api.before do |req, res, ureq|
  if !req.identity.may?(:call_upstream)
    res.set_status(403)
    res.set_body("{\"error\":\"missing capability: call_upstream\"}")
    true
  else
    if UPSTREAM_KEY.length > 0
      ureq.set_header("Authorization", "Bearer " + UPSTREAM_KEY)
    end
    false
  end
end

# Observability. Runs on the forwarded path AND the short-circuit path
# (ures.status is 0 when before_forward rejected) -- so the audit log
# sees denied requests too.
api.after do |req, ures, res|
  res.headers["X-Proxy-Status"]   = ures.status.to_s
  res.headers["X-Proxy-Upstream"] = UPSTREAM
  LOGGER.info("[api_gateway] " + req.verb + " " + req.raw_path +
              " -> " + ures.status.to_s)
  0
end

# Mount whatever paths you proxy (one instance serves many).
Tep.get  "/v1/data",   api
Tep.post "/v1/submit", api

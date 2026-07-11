# examples/llm_gateway -- an LLM API gateway built on Tep::Proxy.
#
# Fronts a remote OpenAI-compatible upstream: swaps the client's
# credential for the server-side key, streams the SSE response back
# unchanged, and emits ONE toy/v1 serving event (kind:eval,
# phase:serve, name:request) per request at end-of-stream (via
# Tep::Events#inference). This is the payoff of
# the proxy streaming battery (chunk 6.2) + the events emitter --
# token-count + latency telemetry with the right cardinality (one
# event per request, not per chunk), using on_stream_end as the
# one-shot finalizer.
#
# Run:
#   UPSTREAM=https://api.openai.com OPENAI_KEY=sk-... \
#   EVENTS_JSONL=/tmp/gateway.events.jsonl \
#     bin/tep build examples/llm_gateway/app.rb -o /tmp/gw && /tmp/gw -p 4567
#
#   # streaming chat completion -> SSE passthrough + one serving event
#   curl -s localhost:4567/v1/chat/completions -H 'content-type: application/json' \
#     -d '{"model":"gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"hi"}]}'
#   tail -1 /tmp/gateway.events.jsonl
#   # {"kind":"eval","phase":"serve","t":3,"name":"request","extra":{
#   #   "model":"gpt-4o-mini","prompt_tokens":0,"completion_tokens":42,
#   #   "latency_us":3000000, ...}}
require 'sinatra'

# Streaming proxying needs the cooperative server (the pump parks on
# io_wait); same constraint as WebSocket.
set :scheduler, :scheduled
set :workers, 1

UPSTREAM     = ENV["UPSTREAM"]   || "http://127.0.0.1:11434"   # e.g. a local ollama
OPENAI_KEY   = ENV["OPENAI_KEY"] || ""
EVENTS       = Tep::Events.new(ENV["EVENTS_JSONL"] || "")      # "" disables emission

on_start do
  EVENTS.run_start("gateway", "proxy", "upstream", UPSTREAM,
                   "{\"server\":\"tep-llm-gateway\"}")
end

# Block-form proxy DSL (lowered to a Tep::Proxy subclass by bin/tep).
gw = Tep::Proxy.new(UPSTREAM)

# Swap the credential: strip whatever the client sent, attach the
# server-side key. Also stamp a coarse start time for the latency
# measurement in on_stream_end (req.ivars is per-request state).
gw.before do |req, res, ureq|
  if OPENAI_KEY.length > 0
    ureq.set_header("Authorization", "Bearer " + OPENAI_KEY)
  end
  req.ivars["t0"] = Time.now.to_i.to_s
  false
end

# Stream when the client asked for it. OpenAI signals streaming with
# `"stream": true` in the JSON body; Tep::Json has no bool getter, so
# we match the literal (with or without the space).
gw.stream_request? do |req|
  b = req.raw_body
  b.include?("\"stream\":true") || b.include?("\"stream\": true")
end

# Pass each SSE event straight through. The framework's StreamStats
# tracks chunk_count / byte_count for us (chunk_count ~ completion
# tokens for this demo; a real gateway would parse delta.content).
gw.on_stream_chunk do |chunk, out, stats|
  out.write(chunk.chunk_text)
  0
end

# One inference event at end-of-stream -- the right cardinality.
gw.on_stream_end do |req, out, stats|
  model = Tep::Json.get_str(req.raw_body, "model")
  t0    = req.ivars["t0"].to_i
  wall  = Time.now.to_i - t0
  if wall < 0
    wall = 0
  end
  extra = "{" +
    Tep::Json.encode_pair_str("request_id", req.req_headers["x-request-id"]) + "," +
    Tep::Json.encode_pair_str("principal_id", req.identity.principal_id) +
  "}"
  # prompt_tokens unknown at the proxy (no tokenizer); completion_tokens
  # approximated by the SSE event count. wall_us is second-resolution
  # (no µs clock) -- fine for seconds-scale LLM latency.
  EVENTS.inference(model, 0, stats.chunk_count, wall * 1000000, extra)
  0
end

Tep.get  "/v1/models",           gw
Tep.post "/v1/chat/completions", gw

# Tep::Events -- toy/v1 event-stream emitter.
#
# Appends newline-delimited JSON (JSONL) in the toy/v1 envelope
# (`docs/events-schema.md` in the toy project): one `run_start` at
# boot, one `inference` per served request, one `run_end` at
# shutdown. The serving stream is structurally indistinguishable
# from a training stream, so a single downstream ingest (the
# research-lab orchestrator) consumes both.
#
# Standalone on purpose: any tep handler can emit (the chatbot's
# existing OpenAI-compat endpoint, a future Tep::Llm::OpenAI::Server,
# a Tep::Proxy gateway via on_stream_end). The full server battery
# (Battery 7) builds on this rather than reimplementing it.
#
#   EVENTS = Tep::Events.new(ENV["EVENTS_JSONL"])   # "" => disabled
#   EVENTS.run_start("gx10", "cpu", "smollm2-135m",
#                    "/srv/models/smollm2-135m.gguf",
#                    "{\"server\":\"tep\",\"cap\":\"infer\"}")
#   # ... per request, after generation completes:
#   EVENTS.inference("smollm2-135m", 12, 8, 87000,
#     "{\"request_id\":\"cmpl-abc\",\"principal_id\":\"user:42\"," +
#     "\"sampling\":{\"temperature\":0.7,\"max_tokens\":256}}")
#   # ... at shutdown:
#   EVENTS.run_end("ok")
#
# Schema choice (was #79): per-request telemetry is `kind:"inference",
# phase:"serve"` -- a distinct kind, NOT an overload of toy/v1's
# `eval` (reserved for held-out training evaluation: loss/ppl/
# samples). tao's recommendation; a served completion shares none of
# eval's defining fields, and overloading `eval` would break tao's
# ingest (which keys the "final eval" on `kind` alone).
#
# Integer-only number fields by design (a tep choice, NOT a spinel
# constraint -- spinel supports Float fully; this module deliberately
# avoids it for serving telemetry):
#   * `t` is integer seconds since run_start (a JSON number; consumers
#     reading it as float get N.0). Sub-second ordering isn't needed
#     for serving telemetry -- per-request latency rides in wall_us.
#   * `wall_us` (microsecond latency) is caller-measured + passed in
#     as an int.
#   * Floats that the schema does carry (sampling.temperature) live in
#     the caller-built `extra` JSON string, which tep emits verbatim.
#     Apps that want native Float support in extra can build their
#     own JSON encoder around the float values.
#
# `started_at` / `ended_at` are ISO-8601 UTC via Sock.sphttp_iso8601_utc
# (spinel's Time.now exposes only integer epoch seconds).
module Tep
  class Events
    def initialize(path)
      @path        = path   # "" disables emission (zero I/O, zero alloc)
      @run_started = 0       # epoch seconds at run_start; basis for relative t
      @req_count   = 0
      @err_count   = 0
      @tok_out     = 0
    end

    # True when a non-empty path was configured. Apps that build the
    # emitter unconditionally can cheaply skip work when disabled.
    def enabled?
      @path.length > 0
    end

    # Emit `run_start` once, before any request. Establishes the
    # relative-t origin even when emission is disabled (so a later
    # enable mid-run wouldn't be needed; cheap either way). host /
    # backend_kind / model_name / model_path are plain strings;
    # config_json is a caller-built JSON object emitted verbatim.
    def run_start(host, backend_kind, model_name, model_path, config_json)
      @run_started = Time.now.to_i
      if @path.length == 0
        return 0
      end
      started = Sock.sphttp_iso8601_utc(@run_started)
      # toy/v1 says host is {name, os, arch} (docs/events-schema.md);
      # was a bare string before #115. os + arch come from uname() via
      # Sock.sphttp_os_kind / sphttp_arch_kind.
      line = "{" +
        Json.encode_pair_str("kind", "run_start") + "," +
        Json.encode_pair_str("schema", "toy/v1") + "," +
        Json.encode_pair_int("t", 0) + "," +
        Json.encode_pair_str("started_at", started) + "," +
        "\"host\":{" +
          Json.encode_pair_str("name", host) + "," +
          Json.encode_pair_str("os",   Sock.sphttp_os_kind) + "," +
          Json.encode_pair_str("arch", Sock.sphttp_arch_kind) +
        "}," +
        "\"backend\":{" + Json.encode_pair_str("kind", backend_kind) + "}," +
        "\"model\":{" +
          Json.encode_pair_str("name", model_name) + "," +
          Json.encode_pair_str("path", model_path) +
        "}," +
        "\"config\":" + config_json +
      "}"
      append_line(line)
    end

    # Emit one inference-time telemetry event in the toy/v1 spec
    # shape (#136): kind:"eval", phase:"serve", name:"request",
    # with model + token counts + latency_us nested inside `extra`
    # alongside whatever the caller passed in extra_json. The
    # producer-facing API stays the same (callers pass
    # prompt_tokens, completion_tokens, wall_us); we rename
    # wall_us -> latency_us at the wire level.
    #
    # extra_json is a caller-built JSON object ("{}" if none)
    # carrying sampling / request_id / principal_id. We strip its
    # outer braces and merge with the spec's per-completion fields
    # to produce the final extra object.
    def inference(model, prompt_tokens, completion_tokens, wall_us, extra_json)
      @req_count = @req_count + 1
      @tok_out   = @tok_out + completion_tokens
      if @path.length == 0
        return 0
      end
      # Build the merged extra: spec fields first, then caller's
      # fields appended (if non-empty).
      extra = "{" +
        Json.encode_pair_str("model", model) + "," +
        Json.encode_pair_int("prompt_tokens", prompt_tokens) + "," +
        Json.encode_pair_int("completion_tokens", completion_tokens) + "," +
        Json.encode_pair_int("latency_us", wall_us)
      caller_inner = ""
      if extra_json.length > 2
        # Strip the outer braces -- "{...}" -> "...".
        caller_inner = extra_json[1, extra_json.length - 2]
      end
      if caller_inner.length > 0
        extra = extra + "," + caller_inner
      end
      extra = extra + "}"
      line = "{" +
        Json.encode_pair_str("kind", "eval") + "," +
        Json.encode_pair_str("phase", "serve") + "," +
        Json.encode_pair_int("t", rel_t) + "," +
        Json.encode_pair_str("name", "request") + "," +
        "\"extra\":" + extra +
      "}"
      append_line(line)
    end

    # Count one server-side error (surfaced in run_end.stats.errors).
    # Separate from emission so the counter advances even when
    # emission is disabled.
    def record_error
      @err_count = @err_count + 1
      0
    end

    # Emit `run_end` once at shutdown using LOCAL counters. reason is
    # "completed" (clean) or "errored" (uncaught failure) -- per
    # toy/v1, quality verdicts on the run are downstream decisions,
    # not encoded here. Used for single-process / workers=1 deployments
    # where the writer is the same process that handled the inferences.
    # For workers>1, see run_end_aggregated below.
    def run_end(reason)
      if @path.length == 0
        return 0
      end
      ended = Sock.sphttp_iso8601_utc(Time.now.to_i)
      line = "{" +
        Json.encode_pair_str("kind", "run_end") + "," +
        Json.encode_pair_int("t", rel_t) + "," +
        Json.encode_pair_str("ended_at", ended) + "," +
        Json.encode_pair_str("reason", reason) + "," +
        "\"stats\":{" +
          Json.encode_pair_int("requests", @req_count) + "," +
          Json.encode_pair_int("errors", @err_count) + "," +
          Json.encode_pair_int("tokens_out", @tok_out) +
        "}" +
      "}"
      append_line(line)
    end

    # Cross-worker run_end: re-read the JSONL + sum inference events
    # so the emitted stats cover every worker's contribution, then
    # emit ONE run_end with aggregated counters. Used by Tep.on_shutdown
    # in the prefork parent (workers>1) -- worker children stop calling
    # run_end at all; only the parent emits, after all workers have
    # exited. Avoids cross-worker IPC entirely.
    def run_end_aggregated(reason)
      if @path.length == 0
        return 0
      end
      reqs = 0
      toks = 0
      # errors aren't yet event-encoded (record_error only bumps a
      # local counter), so cross-worker errors aren't visible here.
      # If a future chunk emits "error" events, sum them too. For
      # now: 0 in aggregated mode.
      errs = 0
      content = File.read(@path)
      lines = content.split("\n")
      i = 0
      while i < lines.length
        line_s = lines[i]
        # #136: inference events are kind:"eval" + phase:"serve" +
        # name:"request". Match the joint shape to avoid counting
        # future non-request eval events (e.g. training-time eval).
        if Tep.str_find(line_s, "\"kind\":\"eval\"", 0) >= 0 &&
           Tep.str_find(line_s, "\"name\":\"request\"", 0) >= 0
          reqs += 1
          # completion_tokens now lives nested inside the `extra`
          # object. Tep::Json.find_value_start walks only the
          # top-level keys (it skips over nested objects), so we
          # have to extract extra first, then get_int within it.
          extra_pos = Json.find_value_start(line_s, "extra")
          if extra_pos >= 0
            obj_end = Json.skip_container(line_s, extra_pos)
            extra_obj = line_s[extra_pos, obj_end - extra_pos]
            toks += Json.get_int(extra_obj, "completion_tokens")
          end
        end
        i += 1
      end
      ended = Sock.sphttp_iso8601_utc(Time.now.to_i)
      out = "{" +
        Json.encode_pair_str("kind", "run_end") + "," +
        Json.encode_pair_int("t", rel_t) + "," +
        Json.encode_pair_str("ended_at", ended) + "," +
        Json.encode_pair_str("reason", reason) + "," +
        "\"stats\":{" +
          Json.encode_pair_int("requests", reqs) + "," +
          Json.encode_pair_int("errors", errs) + "," +
          Json.encode_pair_int("tokens_out", toks) +
        "}" +
      "}"
      append_line(out)
    end

    # Seconds since run_start, clamped at 0 (a clock that goes
    # backwards, or events before run_start, read as t=0).
    def rel_t
      d = Time.now.to_i - @run_started
      if d < 0
        d = 0
      end
      d
    end

    # Append one JSON line. Best-effort, append mode -- mirrors
    # Tep::Logger's file sink. Telemetry must never fail a request, so
    # a malformed/unwritable path degrades to a dropped line rather
    # than a raised error reaching the handler. Callers gate on a
    # non-empty @path before reaching here.
    def append_line(line)
      File.open(@path, "a") do |f|
        f.puts(line)
      end
      0
    end
  end
end

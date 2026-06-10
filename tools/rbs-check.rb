#!/usr/bin/env ruby
# rbs-check.rb -- drift guard for sig/*.rbs against Spinel's inferred types.
#
# tep's sig/ is the type root (tep#199: `spinel --rbs sig` re-pins uncalled
# public methods once the pin moves to a spinel with lenient --rbs). For that
# to be safe, sig/ must stay in lockstep with what Spinel actually infers --
# otherwise a stale/wrong declaration silently mistypes the emitted C. This
# compares the DECLARED signatures in sig/tep/*.rbs against the INFERRED ones
# from `spinel --emit-rbs` on a built tep surface, and reports drift.
#
#   spinel --emit-rbs <app>.tep.rb -o emitted.rbs   # inferred (rake rbs:emit)
#   ruby tools/rbs-check.rb emitted.rbs sig          # declared-vs-inferred
#
# ADVISORY by default (always exits 0): spinel's emit inference is app-specific
# (a param widens to `untyped` when the call site passes a user subclass) and
# has mechanical-return quirks, so most divergence is not a sig/ error. Output
# is bucketed by severity -- only PARAM-SHAPE drift (two concrete param types
# disagree) is the class that actually mistypes generated C (tep#198). Set
# TEP_RBS_STRICT=1 to exit 1 when any param-shape drift is present (CI canary).
#
# Pragmatic, not a full RBS parser: joins multi-line sigs, drops param names,
# canonicalizes namespace + nullability, and matches by Spinel's flat symbol
# name (Tep_<Class path>_[cls_]<method>). Note: reading capture $3 AFTER a
# `$2.sub(...)` would be nil (sub resets $~) -- captures are bound via MatchData.

emitted_path, sig_dir = ARGV[0], (ARGV[1] || "sig")
abort "usage: rbs-check.rb <emitted.rbs> [sig_dir]" unless emitted_path && File.exist?(emitted_path)

# Yield logical RBS lines, joining multi-line method signatures onto one line.
# sig/ wraps many-param sigs across lines:
#     def initialize: (
#       String agent_id,
#       Integer issued_at
#     ) -> void
# A physical-line parser sees only `def initialize: (` and drops the rest. We
# coalesce a `def` whose parens aren't yet balanced / has no `->` with the
# following lines until it is complete. class/module/end lines never start a
# def, so nesting tracking is unaffected.
def logical_lines(path)
  out = []
  buf = nil
  complete = ->(s) { s.count("(") <= s.count(")") && s.include?("->") }
  File.foreach(path) do |raw|
    l = raw.rstrip
    if buf
      buf << " " << l.strip
      (out << buf; buf = nil) if complete.call(buf)
    elsif l =~ /^\s*def\s/ && !complete.call(l)
      buf = l.dup
    else
      out << l
    end
  end
  out << buf if buf
  out
end

# Canonicalize a type token to what actually mistypes generated C, dropping
# distinctions that don't change the emitted type:
#   - namespace qualification: `Tep::WebSocket::Handler` and the bare `Handler`
#     a sig/ file writes inside its own module are the SAME type to the codegen.
#   - nullability: `Tep::Request?` and `Tep::Request` are one pointer slot;
#     spinel's nil-tracking is a precision refinement, not a C-type drift.
# Array[Tep::Route] -> Array[Route]; Tep::Request? -> Request; untyped -> untyped.
def canon_type(t)
  t.to_s
   .gsub(/(?:[A-Z][A-Za-z0-9_]*::)+/, "")   # strip namespace prefixes -> leaf name
   .gsub("?", "")                            # strip nullability
end

# Normalize a type/sig string: drop param NAMES (keep types), drop trailing RBS
# comments (e.g. spinel's "# spinel: widened to untyped (slow path)" note),
# canonicalize each type, collapse spaces.
# `(String event, Tep::Request req) -> Integer` -> `(String,Request)->Integer`
def norm(sig)
  return "" if sig.nil? || sig.strip.empty?
  sig = sig.sub(/#.*\z/, "")               # drop trailing RBS comment / spinel annotation
  params, ret = sig.split("->", 2)
  ptypes = params.to_s.strip.sub(/\A\(/, "").sub(/\)\z/, "").split(",").map do |p|
    p = p.strip
    # an RBS param is "Type name" or "Type" or "?Type name" (optional) etc.
    # keep everything up to the last bareword (the name), if a name is present.
    p = p =~ /\A(.*\S)\s+[a-z_][A-Za-z0-9_]*\z/ ? $1.strip : p
    canon_type(p)
  end
  "(#{ptypes.join(",")})->#{canon_type(ret.to_s.strip)}".gsub(/\s+/, "")
end

# --- inferred: parse emitted.rbs. Class methods come out FLAT under
# `class Object` (`def Tep_X_cls_Y: ...`); instance methods come out NESTED
# (`class Tep::X { def y: ... }`). Build flat names for the nested ones so they
# key the same way as `declared` below. ---
inferred = {}
istack = []
logical_lines(emitted_path).each do |l|
  case l
  when /^\s*(class|module)\s+([A-Za-z0-9_:]+)/
    $2.split("::").each { |c| istack << c }
  when /^\s*end\s*$/
    istack.pop unless istack.empty?
  when /^\s*def\s+(self\.)?([A-Za-z0-9_]+[!?]?):\s*(.+?)\s*$/
    # Bind captures BEFORE the `sub` below: String#sub runs a regexp match
    # that resets the caller's `$~`, so reading `$3` after `$2.sub(...)` in
    # the same statement yields nil (the body would be silently dropped and
    # every sig would normalize to "" -- a name-only check). Hold MatchData.
    m = Regexp.last_match
    cls, name, body = m[1], m[2].sub(/[!?]\z/, ""), m[3]
    if name.start_with?("Tep_")          # already-flat class-method def (under `class Object`)
      inferred[name] = norm(body)
    else
      # Instance method under a flat-named class block, e.g. `class Tep_App`.
      # The class name IS the flat prefix already -- don't re-prepend Tep.
      prefix = istack.last
      if prefix && prefix.start_with?("Tep")
        inferred["#{prefix}_#{cls ? "cls_#{name}" : name}"] = norm(body)
      end
    end
  end
end

# --- declared: walk sig/tep/*.rbs, build Spinel flat names from nesting ---
declared = {}
Dir[File.join(sig_dir, "**", "*.rbs")].sort.each do |f|
  stack = []   # nested class/module path components (without leading Tep)
  logical_lines(f).each do |l|
    case l
    when /^\s*(class|module)\s+([A-Za-z0-9_:]+)/
      $2.split("::").each { |c| stack << c }
    when /^\s*end\s*$/
      stack.pop unless stack.empty?
    when /^\s*def\s+(self\.)?([A-Za-z0-9_]+[!?]?):\s*(.+?)\s*$/
      m = Regexp.last_match                     # hold MatchData: $2.sub resets $~ (see inferred parse)
      is_cls = !m[1].nil?
      mname  = m[2].sub(/[!?]\z/, "")
      path   = stack.dup
      path.shift if path.first == "Tep"        # Tep is the flat prefix
      flat = (["Tep"] + path + [is_cls ? "cls_#{mname}" : mname]).join("_")
      declared[flat] = norm(m[3])
    end
  end
end

drift = []
compared = 0
declared.each do |flat, dsig|
  isig = inferred[flat]
  next unless isig                      # declared-but-not-emitted: not drift (uncalled/dead-ok)
  compared += 1
  drift << [flat, dsig, isig] if dsig != isig
end

if drift.empty?
  puts "rbs-check: OK -- #{compared} of #{declared.size} declared sigs cross-checked " \
       "against inferred (#{inferred.size} emitted), no type/arity drift."
  exit 0
end

# Classify each divergence. Spinel's emit inference is APP-SPECIFIC (a method's
# param widens to `untyped` when the call site passes a user subclass) and has
# mechanical-return quirks (setters/initialize infer `-> Integer`/`-> void`
# regardless of the body's apparent value), so most divergence is NOT a sig/
# error -- only param-SHAPE drift between two concrete types is the class that
# actually mistypes generated C (tep#198's spawn_fiber was one). So this tool
# is ADVISORY: it reports, bucketed by severity, and exits 0. Opt into a hard
# gate on the dangerous bucket alone with TEP_RBS_STRICT=1 (CI canary).
def split_sig(s); p, r = s.split("->", 2); [p.to_s, r.to_s]; end
buckets = { param: [], widen: [], ret: [] }
drift.each do |flat, d, i|
  dp, dr = split_sig(d); ip, ir = split_sig(i)
  if d.include?("untyped") || i.include?("untyped")
    buckets[:widen] << [flat, d, i]      # app-specific poly widening (call site passed a subclass)
  elsif dp != ip
    buckets[:param] << [flat, d, i]      # concrete param-shape drift -- the codegen-dangerous class
  else
    buckets[:ret] << [flat, d, i]        # return-only -- spinel mechanical-return quirk, benign
  end
end

puts "(cross-checked #{compared} of #{declared.size} declared against #{inferred.size} inferred)"
puts "rbs-check: #{drift.size} divergence(s) sig/ vs spinel-inferred " \
     "[#{buckets[:param].size} param-shape, #{buckets[:widen].size} untyped-widening, #{buckets[:ret].size} return-only]"
show = lambda do |title, rows, note|
  next if rows.empty?
  puts "\n== #{title} (#{rows.size}) -- #{note}"
  rows.sort.each { |flat, d, i| puts "  #{flat}\n    sig:      #{d}\n    inferred: #{i}" }
end
show.call("PARAM-SHAPE DRIFT", buckets[:param],
          "concrete param types differ; this is what mistypes codegen -- reconcile sig/ or seeds")
show.call("UNTYPED WIDENING", buckets[:widen],
          "spinel widened to untyped (usually an app subclass at the call site); app-specific, not a sig/ error")
show.call("RETURN-ONLY", buckets[:ret],
          "params agree; return differs (spinel setter/initialize return quirk) -- usually benign")

if ENV["TEP_RBS_STRICT"] == "1" && !buckets[:param].empty?
  warn "\nrbs-check: TEP_RBS_STRICT set and #{buckets[:param].size} param-shape drift(s) present -> failing."
  exit 1
end
exit 0

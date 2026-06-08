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
# Exit 0 if no drift, 1 if drift found. Pragmatic, not a full RBS parser:
# normalizes param names away and matches by Spinel's flat symbol name
# (Tep_<Class path>_[cls_]<method>), so it catches type/arity drift -- the
# thing that actually mistypes codegen -- for human review.

emitted_path, sig_dir = ARGV[0], (ARGV[1] || "sig")
abort "usage: rbs-check.rb <emitted.rbs> [sig_dir]" unless emitted_path && File.exist?(emitted_path)

# Normalize a type/sig string: drop param NAMES (keep types), collapse spaces.
# `(String event, Tep::Request req) -> Integer` -> `(String,Tep::Request)->Integer`
def norm(sig)
  return "" if sig.nil? || sig.strip.empty?
  params, ret = sig.split("->", 2)
  ptypes = params.to_s.strip.sub(/\A\(/, "").sub(/\)\z/, "").split(",").map do |p|
    p = p.strip
    # an RBS param is "Type name" or "Type" or "?Type name" (optional) etc.
    # keep everything up to the last bareword (the name), if a name is present.
    p =~ /\A(.*\S)\s+[a-z_][A-Za-z0-9_]*\z/ ? $1.strip : p
  end
  "(#{ptypes.join(",")})->#{ret.to_s.strip}".gsub(/\s+/, "")
end

# --- inferred: parse emitted.rbs. Class methods come out FLAT under
# `class Object` (`def Tep_X_cls_Y: ...`); instance methods come out NESTED
# (`class Tep::X { def y: ... }`). Build flat names for the nested ones so they
# key the same way as `declared` below. ---
inferred = {}
istack = []
File.foreach(emitted_path) do |l|
  case l
  when /^\s*(class|module)\s+([A-Za-z0-9_:]+)/
    $2.split("::").each { |c| istack << c }
  when /^\s*end\s*$/
    istack.pop unless istack.empty?
  when /^\s*def\s+(self\.)?([A-Za-z0-9_]+[!?]?):\s*(.+?)\s*$/
    cls, name, body = $1, $2.sub(/[!?]\z/, ""), $3
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
  File.foreach(f) do |l|
    case l
    when /^\s*(class|module)\s+([A-Za-z0-9_:]+)/
      $2.split("::").each { |c| stack << c }
    when /^\s*end\s*$/
      stack.pop unless stack.empty?
    when /^\s*def\s+(self\.)?([A-Za-z0-9_]+[!?]?):\s*(.+?)\s*$/
      is_cls = !$1.nil?
      mname  = $2.sub(/[!?]\z/, "")
      path   = stack.dup
      path.shift if path.first == "Tep"        # Tep is the flat prefix
      flat = (["Tep"] + path + [is_cls ? "cls_#{mname}" : mname]).join("_")
      declared[flat] = norm($3)
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
puts "(cross-checked #{compared} of #{declared.size} declared against #{inferred.size} inferred)"
puts "rbs-check: DRIFT in #{drift.size} method(s) (declared sig/ vs spinel-inferred):"
drift.sort.each { |flat, d, i| puts "  #{flat}\n    sig:      #{d}\n    inferred: #{i}" }
exit 1

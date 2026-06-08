require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/test_*.rb"]
  t.warning    = false
end

desc "Build all examples and the bench binary (requires SPINEL on PATH)"
task :build do
  sh "make all"
end

desc "Remove built artefacts"
task :clean do
  sh "make clean"
end

namespace :rbs do
  desc "Syntax-validate every signature under sig/."
  task :validate do
    # `rbs validate` walks each loaded file and checks well-formedness
    # (parser, generics arity, reference resolution within the loaded
    # set). It does NOT cross-check .rb against .rbs -- that's Steep's
    # job, deferred until the surface stabilises.
    #
    # Resolve the rbs CLI from the gem itself rather than assuming it's
    # on PATH. Under `bundle exec` (CI) the bundled rbs is on PATH; on a
    # bare host (e.g. a distro ruby on gx10 where the gem's bin dir
    # isn't exported) it is NOT, and a plain `sh "rbs ..."` fails with
    # 127. Gem.bin_path locates the executable in both setups, and we
    # run it through the current ruby so the shebang/PATH don't matter.
    args = ["--repo", "sig", "-I", "sig", "validate"]
    begin
      sh RbConfig.ruby, Gem.bin_path("rbs", "rbs"), *args
    rescue Gem::Exception
      # rbs not installed as a gem; last resort is a bare PATH lookup.
      sh "rbs", *args
    end
  end

  # DEV-ONLY, OPTIONAL. Export spinel's whole-program inferred signatures
  # as RBS (`spinel --emit-rbs`, available from the f6d5eef pin) so they
  # can be diffed against the hand-authored sig/ to catch drift / find
  # surfaces that degraded to `untyped`. This is NOT wired into :test,
  # :validate, :default, or CI -- it skips cleanly when the spinel on
  # PATH/$SPINEL lacks the flag or there's no built source, so tep never
  # acquires a hard dependency on the tooling. Usage:
  #   make all                       # produce the inlined .tep.rb
  #   rake rbs:emit                  # -> sig/.emitted/<app>.rbs (gitignored)
  #   EMIT_SRC=examples/.foo.tep.rb rake rbs:emit
  task :emit do
    spinel = ENV["SPINEL"] || "spinel"
    src    = ENV["EMIT_SRC"] || "examples/.sinatra_style.tep.rb"
    help   = (`#{spinel} --help 2>&1` rescue "")
    if !help.include?("--emit-rbs")
      warn "rbs:emit: `#{spinel}` has no --emit-rbs (needs the f6d5eef+ pin); " \
           "skipping -- this is optional dev tooling, not a dependency."
      next
    end
    unless File.exist?(src)
      warn "rbs:emit: #{src} not found -- run `make all` first (or set EMIT_SRC); skipping."
      next
    end
    require "fileutils"
    FileUtils.mkdir_p("sig/.emitted")
    out = "sig/.emitted/#{File.basename(src).sub(/\.rb$/, ".rbs")}"
    sh "#{spinel} --emit-rbs #{src} -o #{out}" do |ok, _|
      if ok
        puts "rbs:emit: wrote #{out}. Diff against sig/tep/*.rbs to spot drift / untyped widening."
      else
        warn "rbs:emit: emit failed (non-fatal); skipping."
      end
    end
  end

  # DEV-ONLY drift guard: emit spinel's inferred signatures and fail if sig/
  # has drifted from them (a stale/wrong declaration would silently mistype
  # the emitted C once tep#199's `--rbs sig` is enabled). Like :emit it
  # self-skips cleanly when --emit-rbs is unavailable, so it's never a hard
  # dependency -- but WHEN it can run, it enforces (non-zero on drift). Not in
  # :default/CI by choice; run as `rake rbs:check` or wire as a CI canary.
  #   rake rbs:check                         # uses examples/.sinatra_style.tep.rb
  #   EMIT_SRC=examples/.hello.tep.rb rake rbs:check
  desc "Fail if sig/*.rbs has drifted from spinel's inferred types (dev-only)."
  task :check do
    spinel = ENV["SPINEL"] || "spinel"
    src    = ENV["EMIT_SRC"] || "examples/.sinatra_style.tep.rb"
    help   = (`#{spinel} --help 2>&1` rescue "")
    if !help.include?("--emit-rbs")
      warn "rbs:check: `#{spinel}` has no --emit-rbs (needs the f6d5eef+ pin); " \
           "skipping -- optional dev tooling, not a dependency."
      next
    end
    unless File.exist?(src)
      warn "rbs:check: #{src} not found -- run `make all` first (or set EMIT_SRC); skipping."
      next
    end
    require "tmpdir"
    Dir.mktmpdir("rbs-check") do |d|
      emitted = File.join(d, "emitted.rbs")
      unless system("#{spinel} --emit-rbs #{src} -o #{emitted}")
        warn "rbs:check: emit failed (non-fatal); skipping."
        next
      end
      ok = system(RbConfig.ruby, "tools/rbs-check.rb", emitted, "sig")
      abort "rbs:check: sig/ drifted from spinel-inferred types (above)" unless ok
    end
  end
end

task default: :test

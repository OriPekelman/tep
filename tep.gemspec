require_relative "lib/tep/version"

Gem::Specification.new do |s|
  s.name        = "tep"
  s.version     = Tep::VERSION
  s.summary     = "A Sinatra-flavoured web framework that compiles to a native binary via Spinel"
  s.description = <<~TEXT.strip
    tep is a small Sinatra-style DSL targeting the Spinel AOT Ruby
    compiler. The translator turns a Sinatra-classic source file into
    a self-contained native binary -- ~80 KB on Linux, no Ruby runtime.
    Pre-alpha: primary purpose is exercising Spinel against real-world
    Ruby usage; the framework is the test vehicle.
  TEXT
  s.authors     = ["Ori Pekelman"]
  s.email       = ["ori@pekelman.com"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/OriPekelman/tep"
  s.metadata    = {
    "source_code_uri"      => "https://github.com/OriPekelman/tep",
    "bug_tracker_uri"      => "https://github.com/OriPekelman/tep/issues",
    "documentation_uri"    => "https://github.com/OriPekelman/tep#readme",
    "rubygems_mfa_required" => "true",
  }

  # Shown on `gem install tep`. The gem is Spinel-AOT source, not a
  # CRuby library -- reinforce the model the lib/tep.rb stock-Ruby guard
  # also enforces at require-time, so a `gem install` user isn't left
  # guessing why `require "tep"` raises.
  s.post_install_message = <<~MSG
    tep is a Spinel-AOT framework: it compiles your Sinatra-style app to
    a native binary -- there is no `require "tep"` runtime under CRuby.
      build an app:   tep build app.rb && ./app -p 4567
      or vendor it:   declare `gem "tep"` in a bundler-spinel (spinelgems)
                      Gemfile, then `spinel-compat vendor`.
    Docs: https://github.com/OriPekelman/tep
  MSG

  # Runtime target is Spinel's Ruby level (3.2.x — the gx10 host Ruby
  # and toy's `ruby "3.2.3"` engine marker both sit here). Was 3.4.0,
  # justified by "Prism is bundled" — but Prism is now a dev-only
  # dependency (the translator's build-time parser), so it no longer
  # constrains the runtime/vendored lib/. Lowering this unblocks a
  # consumer whose Gemfile declares `ruby "3.2.3"` (e.g. toy) from
  # `bundle lock`-ing `gem "tep"`. bin/tep itself wants Ruby 3.3+ for
  # bundled Prism (or the prism dev-dep on 3.2); that's a dev-env
  # concern, not a gem-install constraint.
  s.required_ruby_version = ">= 3.2.0"

  # Ship only git-TRACKED files matching these globs. Intersecting with
  # `git ls-files` is what keeps gitignored build artifacts OUT: the
  # compiled C objects (lib/tep/*.o) and the native example binaries
  # (examples/hello, pg_hello, ...) land in-tree after `make`, and a bare
  # Dir glob would scoop ~1.7 MB of stale, platform-specific junk into
  # the gem. The `.reject` is a belt-and-suspenders for a no-git build
  # (e.g. from an unpacked source tree).
  tracked = (`git ls-files -z`.split("\x0") rescue [])
  s.files = Dir[
    "README.md", "LICENSE", "SINATRA_COMPAT.md",
    "Makefile",
    # Declares tep's Spinel C-extension shape (the @TEP_*@ placeholder
    # substitutions). Read by bin/tep and by `spinel-compat vendor` --
    # must ship at the gem root so it survives `gem unpack`. See #98.
    "spinel-ext.json",
    "bin/tep",
    "lib/**/*",
    "examples/**/*",
    "public/**/*",
    "test/**/*"
  ].reject { |f| File.directory?(f) || f =~ /\.(o|so|a|dylib|bundle)$/ }
   .select { |f| tracked.empty? || tracked.include?(f) }

  s.bindir              = "bin"
  s.executables         = ["tep"]
  s.require_paths       = ["lib"]

  # `bin/tep` uses Prism (bundled with Ruby >= 3.4) at build-time to
  # parse the user's Sinatra-style source. It is NOT a runtime
  # dependency -- the compiled binary embeds everything, and Prism
  # ships with the Ruby that runs the translator.
  #
  # Declared development-only on purpose: a consumer that does
  # `gem "tep", path:/git:` + `bundle lock` (e.g. toy vendoring tep
  # via the bundler-spinel / spinelgems convention) must NOT pull
  # prism into its runtime lock -- prism is a native C-extension
  # Spinel can't compile, so the compat probe would (correctly)
  # reject it. Keeping it dev-only leaves the consumer's lock clean.
  s.add_development_dependency "prism", "~> 1.0"
end

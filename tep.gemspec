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
    "source_code_uri"   => "https://github.com/OriPekelman/tep",
    "bug_tracker_uri"   => "https://github.com/OriPekelman/tep/issues",
    "documentation_uri" => "https://github.com/OriPekelman/tep#readme",
  }

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

  s.files = Dir[
    "README.md", "LICENSE", "SINATRA_COMPAT.md",
    "Makefile",
    "bin/tep",
    "lib/**/*",
    "examples/**/*",
    "public/**/*",
    "test/**/*"
  ].reject { |f| File.directory?(f) }

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

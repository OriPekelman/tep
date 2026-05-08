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

  s.required_ruby_version = ">= 3.4.0"   # Prism is bundled

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

  # `bin/tep` uses Prism (bundled with Ruby >= 3.3) at build-time to
  # parse the user's Sinatra-style source. No runtime Ruby
  # dependencies -- the compiled binary embeds everything.
  s.add_runtime_dependency "prism", "~> 1.0"
end

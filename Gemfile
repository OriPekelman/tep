source "https://rubygems.org"

# Dev-side dependencies. Tep's runtime is spinel-AOT'd and has no
# Ruby gem dependencies; the gems below are for authoring + testing
# on the host (CI + dev workflow). Spinel doesn't see this file.

# Test runner.
gem "rake"
gem "minitest"

# Stdlib-bundled-gems Ruby 3.4 stopped default-requiring. test_jwt
# uses Base64 to decode a JWT payload during the tamper test.
gem "base64"

# Library-shipped type signatures live under `sig/`. RBS gives us
# syntax validation today (`rake rbs:validate`) and IDE tooling
# integration; spinel-side consumption is tracked at #6.
gem "rbs"

# tep's one real runtime dep (tep#217): bin/tep resolves spinel_kit via
# Gem::Specification, and under `bundle exec` (rake test spawning
# bin/tep) only Gemfile gems are visible -- so it must be declared here
# as well as in the gemspec.
gem "spinel_kit", ">= 0.3.0"

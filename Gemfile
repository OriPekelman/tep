source "https://rubygems.org"

# Dev-side dependencies. Tep's runtime is spinel-AOT'd and has no
# Ruby gem dependencies; the gems below are for authoring + testing
# on the host (CI + dev workflow). Spinel doesn't see this file.

# Test runner.
gem "rake"
gem "minitest"

# Library-shipped type signatures live under `sig/`. RBS gives us
# syntax validation today (`rake rbs:validate`) and IDE tooling
# integration; spinel-side consumption is tracked at #6.
gem "rbs"

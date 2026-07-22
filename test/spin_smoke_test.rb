# spin-shape smoke: pure-compute surfaces through the package require root.
# CRuby-parity oracle (no .expected committed): must print identically under
# `ruby` — exercises Tep::Json (absorbed codec, tep#217) and SpinelKit (dep).
require "tep/json"
require "tep/json_decoder"
require "spinel_kit/url"

puts Tep::Json.encode_pair_str("name", "spin")
puts Tep::Json.quote("a\"b")
puts Tep::Json.from_str_hash({ "k" => "v" })
puts Tep::Json.get_str("{\"s\":\"hello\"}", "s")
puts Tep::Json.get_int("{\"n\":42}", "n")
puts SpinelKit::Url.escape("a b&c")
puts SpinelKit::Url.parse_query("x=1&y=2").length

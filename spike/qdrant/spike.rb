# Spike: drive the qdrant-ruby gem's vendored-verbatim resource classes
# under spinel, transported by Tep::Http (no Faraday). Talks to a real
# Qdrant over plain HTTP -- in practice a local TLS-terminating proxy in
# front of the HTTPS-only Qdrant Cloud endpoint (tep has no TLS).
#
#   QDRANT_URL      e.g. http://127.0.0.1:6333  (the proxy front)
#   QDRANT_API_KEY  forwarded as the api-key header

# NOTE: requiring the whole framework is unavoidable -- Tep::Http pulls
# Tep::Scheduler which pulls Tep::APP, i.e. there is no minimal HTTP-only
# subset. Under spinel's whole-program name-based type inference, adding
# the gem's Qdrant::Client / Connection classes to that program poisons
# unrelated tep types (sp_Qdrant_Client leaks into Tep::WebSocket::Driver).
# See SPIKE.md finding #3 -- this program does not currently compile
# against full tep; it is kept as the reproduction.
require_relative "qdrant_shim"
require_relative "vendor/qdrant/version"
require_relative "vendor/qdrant/base"
require_relative "vendor/qdrant/collections"
require_relative "vendor/qdrant/points"
require_relative "vendor/qdrant/service"

url = ENV["QDRANT_URL"]
key = ENV["QDRANT_API_KEY"]
url = "http://127.0.0.1:6333" if url.nil? || url.length == 0
key = "" if key.nil?

puts "=== qdrant-ruby " + Qdrant::VERSION + " resource classes via Tep::Http shim ==="
client = Qdrant::Client.new(url, key)

# READ PATH -- the gem's actual Qdrant::Collections#list executes here
# (GET /collections, returns response.body). Verbatim gem code.
resp = client.collections.list
puts "[read] Collections#list ->"
puts resp

# WRITE PATH boundary -- Collections#create builds a heterogeneous JSON
# body the shim can't serialize under spinel; the gem method runs but
# the transport refuses.
begin
  cfg = {}
  cfg["size"] = 4
  cfg["distance"] = "Cosine"
  client.collections.create(collection_name: "tep_spike", vectors: cfg)
  puts "[write] Collections#create -> unexpectedly succeeded"
rescue Qdrant::Error => e
  puts "[write] Collections#create blocked (expected): " + e.message
end

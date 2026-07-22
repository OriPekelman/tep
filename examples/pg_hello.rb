# Tep::PG smoke test app -- exercises the v1 PG battery surface.
#
#   GET /             - libpq + server version + a SELECT round-trip
#   GET /tables       - list user tables in the public schema
#   GET /error        - issues a deliberate SELECT against a missing
#                       table, demonstrates the v1 result.ok? check
#
# Set PG_URL in the environment (default: postgresql:///postgres,
# the admin DB on localhost via Unix socket).
#
#   PG_URL=postgresql://postgres:postgres@127.0.0.1/postgres \
#     ./examples/pg_hello -p 4567
#
# v1 returns Results-with-ok? rather than raising on error -- spinel's
# rescue dispatch can't match module-namespaced exception classes
# today (matz/spinel#627). Once that lands, this example collapses
# to the AR-shape `rescue PG::Error => e`.
require_relative "../lib/tep"
require_relative "../lib/tep/pg"   # opt-in PG backend (#216)

PG_URL = ENV["PG_URL"] != nil && ENV["PG_URL"].length > 0 ? ENV["PG_URL"] : "postgresql:///postgres"

get '/' do
  c = PG.connect(PG_URL)
  if !c.connected?
    res.set_status(503)
    "PG.connect failed: " + c.last_error_message
  else
    sv = c.server_version
    r = c.exec("SELECT 1 AS one, 'hello' AS greeting")
    body = "libpq " + PG.libpq_version + "\n" +
           "server_version: " + sv.to_s + "\n" +
           "row 0: " + r.getvalue(0, 0) + " / " + r.getvalue(0, 1) + "\n"
    r.clear
    c.close
    res.headers["Content-Type"] = "text/plain"
    body
  end
end

get '/tables' do
  c = PG.connect(PG_URL)
  r = c.exec("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename")
  out = "tables (" + r.ntuples.to_s + "):\n"
  i = 0
  n = r.ntuples
  while i < n
    out = out + "  " + r.getvalue(i, 0) + "\n"
    i += 1
  end
  r.clear
  c.close
  res.headers["Content-Type"] = "text/plain"
  out
end

# exec raises the SQLSTATE-mapped PG::Error subclass on failure (the
# ruby-pg / AR shape). Rescue the leaf (PG::UndefinedTable) or the base
# (PG::Error); the SQLSTATE / message stay on the connection's last_*.
get '/error' do
  c = PG.connect(PG_URL)
  out = ""
  begin
    r = c.exec("SELECT * FROM tep_no_such_table")
    r.clear
    out = "unexpected: query succeeded"
  rescue PG::UndefinedTable => e
    out = "rescued PG::UndefinedTable\n" +
          "sqlstate: " + c.last_sqlstate + "\n" +
          "is undefined-table? " + (c.last_sqlstate == "42P01" ? "yes" : "no") + "\n" +
          # WORKAROUND -- still open at SPINEL_PIN (re-checked at the
          # ad2b71ad re-pin: `e.is_a?(PG::Error)` here is rejected as
          # `unsupported call: is_a? recv=LocalVariableRead argc=1`).
          # `e` is the rescued exception, typed PG::UndefinedTable -- a
          # whole-program is_a? against the namespaced ancestor PG::Error
          # isn't lowered yet. Minimal `rescue Sub => e; e.is_a?(Super)`
          # compiles fine; only the full program trips it. Since `e` is
          # always a PG::Error subclass here, hardcode "yes". Restore
          #   (e.is_a?(PG::Error) ? "yes" : "no")
          # once is_a?-on-rescued-namespaced-ancestor lowers (matz/spinel#3260:
          # the trigger is rescued-local receiver + constant-PATH class arg).
          "is PG::Error? " + "yes" + "\n" +
          "message: " + e.message
  end
  c.close
  res.headers["Content-Type"] = "text/plain"
  out
end

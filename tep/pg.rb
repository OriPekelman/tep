# spin require-root shim (tep#234): `require "tep/pg"` — the PG opt-in
# (tep#216) — resolves to <package root>/tep/pg.rb under spin. Bridges
# to the real feature under lib/ until the spin migration completes.
require_relative "../lib/tep/pg"

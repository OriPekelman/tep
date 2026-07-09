# spin require-root shim (tep#234). Under spin, the package root is the
# require root: `require "tep"` resolves here. The library itself stays
# under lib/ (gem layout, Makefile/spinel-ext.json build path) until the
# spin migration completes; this shim just bridges the two layouts.
# Inert at the current pin — nothing on the Makefile path requires it.
require_relative "lib/tep"

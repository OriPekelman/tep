#!/usr/bin/env bash
# Vendor the SpinelKit lib files tep depends on into lib/spinel_kit/ (+ sig).
#
# spinel_kit is a published gem (github.com/OriPekelman/spinelkit,
# rubygems.org/gems/spinel_kit) -- the single source of truth. The CLEAN way to
# consume it would be `gem "spinel_kit"` + `spinel-compat vendor`, but that flow
# does not yet support transitive gem->gem dependencies (no topo-sorted deps.rb,
# no inter-gem require resolution) -- tracked at OriPekelman/spinelgems#19.
#
# INTERIM (until #19 lands): because tep is spinel-AOT'd with no runtime gem
# resolution -- its lib is inlined by bin/tep via require_relative, and travels
# into end-user apps when tep is itself vendored -- we copy the surface tep uses
# (the JSON codec: encoders + decoders, and the logger) into lib/spinel_kit/ so
# it travels with tep. Each file is stamped with a do-not-edit-here header. tep
# does NOT use the builder or Git, so those are not vendored (Spinel has no
# tree-shaking; vendor only what you compile).
#
# Re-sync from the upstream checkout:  make vendor-spinelkit
# Override the source checkout:         SPINELKIT_DIR=/path/to/spinelkit make vendor-spinelkit
set -euo pipefail

SPINELKIT_DIR="${SPINELKIT_DIR:-$(cd "$(dirname "$0")/../../spinelkit" && pwd)}"
TEP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$SPINELKIT_DIR/lib/spinel_kit" ]; then
  echo "vendor-spinelkit: SpinelKit not found at $SPINELKIT_DIR (set SPINELKIT_DIR)" >&2
  exit 1
fi

REV="$(git -C "$SPINELKIT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
LIB_FILES="json.rb json_decoder.rb log.rb"
SIG_FILES="json.rbs json_decoder.rbs log.rbs"

mkdir -p "$TEP_ROOT/lib/spinel_kit" "$TEP_ROOT/sig/spinel_kit"

stamp () { # $1=src $2=dst $3=comment-prefix
  {
    printf '%s VENDORED from OriPekelman/spinelkit @ %s -- DO NOT EDIT HERE.\n' "$3" "$REV"
    printf '%s Edit upstream and re-sync with `make vendor-spinelkit`.\n' "$3"
    cat "$1"
  } > "$2"
}

for f in $LIB_FILES; do
  stamp "$SPINELKIT_DIR/lib/spinel_kit/$f" "$TEP_ROOT/lib/spinel_kit/$f" "#"
done
for f in $SIG_FILES; do
  stamp "$SPINELKIT_DIR/sig/spinel_kit/$f" "$TEP_ROOT/sig/spinel_kit/$f" "#"
done

echo "vendor-spinelkit: synced lib(${LIB_FILES// /, }) + sig from $SPINELKIT_DIR @ $REV"

#!/usr/bin/env bash
# spinel-fresh.sh -- ensure the spinel checkout is on the commit
# tep expects to compile against before tests / builds run.
#
# Pin model
# ---------
# Tep keeps a SPINEL_PIN file at the repo root containing a single
# git ref (commit SHA or tag). This script ensures the spinel
# checkout is on that ref. The pin gets bumped via PR whenever
# we verify a newer spinel commit works with tep -- so tep's
# spinel-tracking stays explicit + reviewable rather than
# silently floating on master.
#
# Without SPINEL_PIN, falls back to the pre-pin behavior (track
# matz/spinel master).
#
# This script:
#
#   1. Locates the spinel checkout (env, sibling, or ~/sites/spinel).
#   2. If SPINEL_PIN exists at tep root: fetches origin + checks
#      out the pinned ref (detached HEAD).
#   3. Otherwise: `git fetch origin master`, fast-forward if ahead.
#   4. Rebuilds spinel_codegen if its source is newer than the binary.
#
# Skip with `TEP_SKIP_SPINEL_FRESH=1` (CI containers, frozen dev
# loops, branch work, etc.).
#
# Set TEP_SPINEL_DIR to override the lookup. If no checkout is
# found we exit 0 (don't fail the build) and warn -- callers may
# rely on a system-installed `spinel` on PATH.

set -euo pipefail

if [ "${TEP_SKIP_SPINEL_FRESH:-0}" = "1" ]; then
    exit 0
fi

# Resolve spinel dir: env > sibling-of-tep > ~/sites/spinel.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

candidate=""
if [ -n "${TEP_SPINEL_DIR:-}" ]; then
    candidate="$TEP_SPINEL_DIR"
elif [ -d "$TEP_DIR/../spinel/.git" ]; then
    # tep and spinel as direct siblings (e.g. ~/sites/tep + ~/sites/spinel)
    candidate="$(cd "$TEP_DIR/../spinel" && pwd)"
elif [ -d "$HOME/sites/spinel/.git" ]; then
    candidate="$HOME/sites/spinel"
fi

if [ -z "$candidate" ] || [ ! -d "$candidate/.git" ]; then
    echo "tep: no spinel checkout found (set TEP_SPINEL_DIR to override; relying on PATH)" >&2
    exit 0
fi

cd "$candidate"

pin_file="$TEP_DIR/SPINEL_PIN"
if [ -f "$pin_file" ]; then
    # Pin mode: read the ref + ensure HEAD matches it.
    pinned_ref="$(head -n1 "$pin_file" | tr -d '[:space:]')"
    cur_sha="$(git rev-parse HEAD)"
    pin_sha="$(git rev-parse "$pinned_ref^{commit}" 2>/dev/null || echo "")"
    if [ -z "$pin_sha" ]; then
        # Pin not in local clone yet -- fetch + retry.
        git fetch --quiet origin || true
        pin_sha="$(git rev-parse "$pinned_ref^{commit}" 2>/dev/null || echo "")"
    fi
    if [ -z "$pin_sha" ]; then
        echo "tep: SPINEL_PIN '$pinned_ref' not resolvable in $candidate; skipping checkout" >&2
    elif [ "$cur_sha" != "$pin_sha" ]; then
        echo "tep: pinning spinel to $pinned_ref ($pin_sha)..." >&2
        git -c advice.detachedHead=false checkout --quiet "$pin_sha"
    fi
else
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "master" ]; then
        echo "tep: spinel on branch '$current_branch' (not master); skipping fetch+pull" >&2
    else
        git fetch --quiet origin master || true
        behind="$(git rev-list --count HEAD..origin/master 2>/dev/null || echo 0)"
        if [ "$behind" -gt 0 ]; then
            echo "tep: pulling $behind new spinel commit(s) from matz/spinel master..." >&2
            git pull --ff-only --quiet origin master
        fi
    fi
fi

# Rebuild only if codegen source is newer than the binary, OR the
# binary doesn't exist yet. Skip when up-to-date so this script
# stays cheap on the fast path (`make test` after a no-op fetch).
need_rebuild=0
if [ ! -x "spinel_codegen" ]; then
    need_rebuild=1
elif [ "spinel_codegen.rb" -nt "spinel_codegen" ]; then
    need_rebuild=1
fi

if [ "$need_rebuild" = "1" ]; then
    echo "tep: rebuilding spinel_codegen (this is slow -- CRuby bootstrap, ~5min)..." >&2
    make -j8 spinel_codegen >&2
fi

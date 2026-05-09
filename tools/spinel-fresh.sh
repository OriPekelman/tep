#!/usr/bin/env bash
# spinel-fresh.sh -- ensure the spinel checkout is up to date with
# matz/spinel master before tep tests / builds run against it.
#
# Spinel moves quickly; tep regularly rides on its tip. Keeping a
# stale local checkout is a fast way to chase ghost regressions.
# This script:
#
#   1. Locates the spinel checkout (env, sibling, or ~/sites/spinel).
#   2. `git fetch origin master`.
#   3. If origin/master is ahead of HEAD AND we're on master:
#        pull + rebuild spinel_codegen.
#   4. Otherwise, no-op.
#
# Skip with `TEP_SKIP_SPINEL_FRESH=1` (CI containers, frozen dev
# loops, branch work, etc.). On a non-master branch we warn and
# skip the pull but still rebuild if the binary is older than the
# source -- the developer is presumably iterating on spinel itself.
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
elif [ -d "$TEP_DIR/../../spinel/.git" ]; then
    # tep at sites/sinatra_spinel/tep, spinel at sites/spinel
    candidate="$(cd "$TEP_DIR/../../spinel" && pwd)"
elif [ -d "$TEP_DIR/../spinel/.git" ]; then
    # tep and spinel as direct siblings
    candidate="$(cd "$TEP_DIR/../spinel" && pwd)"
elif [ -d "$HOME/sites/spinel/.git" ]; then
    candidate="$HOME/sites/spinel"
fi

if [ -z "$candidate" ] || [ ! -d "$candidate/.git" ]; then
    echo "tep: no spinel checkout found (set TEP_SPINEL_DIR to override; relying on PATH)" >&2
    exit 0
fi

cd "$candidate"

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

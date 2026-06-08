#!/bin/bash
# tests/feature-sweep-worktrees/_lib.sh
# Shared helpers for the feature-sweep-worktrees split test suite.
#
# Sourced by each split file (registry.sh / orphan.sh / gh-stub.sh /
# empty-parent.sh / validation.sh) so the file can also run standalone.
#
# Provides:
#   - SWEEP path
#   - PASS / FAIL counters and pass / fail helpers
#   - run_with_timeout wrapper
#   - TMPDIR_BASE + cleanup trap
#   - init_repo / add_worktree / make_stale repo setup helpers
#   - ci_field JSON field extractor
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_SWEEP_LIB_SOURCED:-}" ]; then
    return 0
fi
_SWEEP_LIB_SOURCED=1

set -uo pipefail

# AGENTS_DIR resolves to the agents repo root (two levels up from this lib file).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-worktrees.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Repo / worktree setup helpers
# ─────────────────────────────────────────────────────────────────────────────

# Create a bare-ish source repo at $1 with one commit on main.
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Add a linked worktree at $2 on branch $3 from source repo $1.
add_worktree() {
    local repo="$1" wpath="$2" branch="$3"
    (cd "$repo" && git worktree add -q -b "$branch" "$wpath" 2>/dev/null)
}

# Backdate the worktree directory mtime to look "stale" (older than threshold).
make_stale() {
    local p="$1"
    # 30 days ago
    if command -v touch >/dev/null 2>&1; then
        touch -d "30 days ago" "$p" 2>/dev/null || touch -t 202401010000 "$p" 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON field extractor (used by --ci-mode tests).
# $1: JSON, $2: key → prints integer value or empty.
# ─────────────────────────────────────────────────────────────────────────────

ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            try {
                const d = JSON.parse(b);
                if (process.argv[1] in d) console.log(d[process.argv[1]]);
            } catch (e) { /* swallow */ }
        });
    " -- "$2" 2>/dev/null
}

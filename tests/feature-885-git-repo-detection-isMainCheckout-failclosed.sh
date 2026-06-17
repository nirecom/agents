#!/bin/bash
# tests/feature-885-git-repo-detection-isMainCheckout-failclosed.sh
# Tests: hooks/enforce-worktree/git-repo-detection.js
# Tags: git-repo-detection, isMainCheckout, fail-closed, axis-a, feature-885
# Tests for issue #885 — isMainCheckout() becomes trivalue:
#   * true  → main worktree
#   * false → linked worktree
#   * null  → detection failed (fail-closed: caller should treat as ambiguous)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

MODULE="$AGENTS_DIR/hooks/enforce-worktree/git-repo-detection.js"
MODULE_NODE="$_AGENTS_DIR_NODE/hooks/enforce-worktree/git-repo-detection.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$MODULE" ]; then
    skip "git-repo-detection.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- G1: main worktree path → true ------------------------------------------
MAIN_REPO="$(cd "$AGENTS_DIR" && git rev-parse --git-common-dir 2>/dev/null)"
MAIN_TOP=""
if [ -n "$MAIN_REPO" ]; then
    # The main worktree contains .git as a directory (not file).
    # Find via git: --git-common-dir is the canonical .git of the main worktree.
    MAIN_TOP="$(dirname "$MAIN_REPO")"
    # Resolve to absolute.
    MAIN_TOP="$(cd "$MAIN_TOP" 2>/dev/null && pwd)"
fi

if [ -z "$MAIN_TOP" ] || [ ! -d "$MAIN_TOP" ]; then
    skip "G1: cannot resolve main worktree path"
else
    if command -v cygpath >/dev/null 2>&1; then
        MAIN_TOP_NODE="$(cygpath -m "$MAIN_TOP")"
    else
        MAIN_TOP_NODE="$MAIN_TOP"
    fi
    out=$(run_with_timeout 8 node -e "
const m = require('$MODULE_NODE');
const r = m.isMainCheckout('$MAIN_TOP_NODE');
if (r !== true) { console.error('expected true, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "G1: isMainCheckout returns true for main worktree"
    else
        fail "G1: isMainCheckout returns true for main worktree (rc=$rc, out=$out)"
    fi
fi

# --- G2: linked worktree path → false ---------------------------------------
LINKED_TOP="$AGENTS_DIR"
LINKED_TOP="$(cd "$LINKED_TOP" 2>/dev/null && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    LINKED_TOP_NODE="$(cygpath -m "$LINKED_TOP")"
else
    LINKED_TOP_NODE="$LINKED_TOP"
fi
# Verify this IS a linked worktree (else skip).
common=$(git -C "$AGENTS_DIR" rev-parse --git-common-dir 2>/dev/null)
gitdir=$(git -C "$AGENTS_DIR" rev-parse --git-dir 2>/dev/null)
if [ "$common" = "$gitdir" ]; then
    skip "G2: agents repo is not a linked worktree in this environment"
else
    out=$(run_with_timeout 8 node -e "
const m = require('$MODULE_NODE');
const r = m.isMainCheckout('$LINKED_TOP_NODE');
if (r !== false) { console.error('expected false, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "G2: isMainCheckout returns false for linked worktree"
    else
        fail "G2: isMainCheckout returns false for linked worktree (rc=$rc, out=$out)"
    fi
fi

# --- G3: git rev-parse returns non-zero → null (fail-closed) ----------------
# Use a non-git directory: spawnSync returns status != 0 → expect null (post-#885).
TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'feat885g')
if command -v cygpath >/dev/null 2>&1; then
    TMPDIR_NODE="$(cygpath -m "$TMPDIR")"
else
    TMPDIR_NODE="$TMPDIR"
fi
out=$(run_with_timeout 8 node -e "
const m = require('$MODULE_NODE');
const r = m.isMainCheckout('$TMPDIR_NODE');
if (r !== null) { console.error('expected null (fail-closed), got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
rc=$?
rm -rf "$TMPDIR"
if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
    pass "G3: non-git cwd → isMainCheckout returns null (fail-closed)"
else
    fail "G3: non-git cwd → isMainCheckout returns null (rc=$rc, out=$out)"
fi

# --- G4: spawnSync exception path → false (existing behavior) ---------------
# Trigger via a cwd that doesn't exist: spawnSync throws ENOENT.
out=$(run_with_timeout 8 node -e "
const m = require('$MODULE_NODE');
const r = m.isMainCheckout('/nonexistent/path/that/should/not/exist/zzz');
if (r !== false) { console.error('expected false on exception, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
    pass "G4: spawnSync throws → isMainCheckout returns false (existing behavior)"
else
    fail "G4: spawnSync throws → isMainCheckout returns false (rc=$rc, out=$out)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

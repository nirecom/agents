#!/bin/bash
# tests/fix-296-hook-cwd-drift-enforce.sh
#
# Integration tests for hooks/enforce-worktree.js cwd-drift fix (issue #296).
#
# Verifies that:
#   - findRepoRootForBash() honors a leading `cd <abs-path>` in the command
#     (in addition to the existing `git -C <path>` path).
#   - getSessionRepoRoots() picks up a payload-derived repo root cache so the
#     enforced set can include the linked worktree even when process.cwd() is
#     the main worktree.
#
# These functions are not yet exported from hooks/enforce-worktree.js.
# Pre-implementation, every L-case fails with NOT_EXPORTED (clean assertion
# failure, not a node crash).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-worktree.js" ]; then
    echo "FAIL: hooks/enforce-worktree.js not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Normalize a path for comparison: backslashes → forward slashes, lowercase,
# trailing slash stripped. Git on Windows returns C:/path-style strings;
# Node may return either form depending on the call site.
norm_path() {
    local p="$1"
    p="${p//\\//}"
    p="${p%/}"
    echo "$p" | tr '[:upper:]' '[:lower:]'
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: a main repo + a linked worktree under a temp dir.
# ─────────────────────────────────────────────────────────────────────────────

setup_repo() {
    TMPDIR_E="$(mktemp -d 2>/dev/null || mktemp -d -t enforce_test)"
    MAIN="$TMPDIR_E/main"
    LINKED="$TMPDIR_E/linked"
    # Empty hooks dir so the global core.hooksPath (which points at the agents
    # pre-commit hook) does NOT run against the temp fixture repo.
    HOOKS_NULL="$TMPDIR_E/null-hooks"
    mkdir -p "$HOOKS_NULL"
    git init -q "$MAIN"
    (
        cd "$MAIN"
        git config core.hooksPath "$HOOKS_NULL"
        git config user.email t@example.com
        git config user.name "T"
        echo a > a.txt
        git add a.txt
        git -c commit.gpgsign=false commit -q -m init
    )
    git -C "$MAIN" -c core.hooksPath="$HOOKS_NULL" worktree add -q "$LINKED" -b test/linked-296 >/dev/null 2>&1
    # Node-friendly forms (forward-slash + drive letter on Windows).
    if command -v cygpath >/dev/null 2>&1; then
        MAIN_NODE="$(cygpath -m "$MAIN")"
        LINKED_NODE="$(cygpath -m "$LINKED")"
        # For embedding in command strings, the Windows backslash form mirrors
        # real Bash-tool input on Windows.
        MAIN_LITERAL="$(cygpath -w "$MAIN")"
        LINKED_LITERAL="$(cygpath -w "$LINKED")"
    else
        MAIN_NODE="$MAIN"
        LINKED_NODE="$LINKED"
        MAIN_LITERAL="$MAIN"
        LINKED_LITERAL="$LINKED"
    fi
}

cleanup_repo() {
    if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
        git -C "$MAIN" worktree remove -f "$LINKED" >/dev/null 2>&1 || true
    fi
    [ -n "${TMPDIR_E:-}" ] && [ -d "$TMPDIR_E" ] && rm -rf "$TMPDIR_E" 2>/dev/null || true
}

setup_repo
trap cleanup_repo EXIT INT TERM HUP

# ─────────────────────────────────────────────────────────────────────────────
# Helper: invoke findRepoRootForBash(cmd) from cwd=MAIN and return its output.
# ─────────────────────────────────────────────────────────────────────────────
call_find_repo_root() {
    local cmd="$1"
    (
        cd "$MAIN" && run_with_timeout 30 node -e "
          try {
            const m = require('$HOOK');
            if (typeof m.findRepoRootForBash !== 'function') {
              console.log('NOT_EXPORTED'); process.exit(2);
            }
            const r = m.findRepoRootForBash(process.argv[1]);
            console.log(r === null || r === undefined ? '' : r);
          } catch(e) { console.log('ERROR: '+e.message); }
        " -- "$cmd" 2>/dev/null
    )
}

assert_root_eq() {
    local id="$1"
    local cmd="$2"
    local expected_node_path="$3"
    local r got exp
    r="$(call_find_repo_root "$cmd")"
    case "$r" in
        NOT_EXPORTED) fail "$id: findRepoRootForBash not exported"; return ;;
        ERROR*) fail "$id: $r"; return ;;
    esac
    got="$(norm_path "$r")"
    exp="$(norm_path "$expected_node_path")"
    if [ "$got" = "$exp" ]; then
        pass "$id: $cmd → $r"
    else
        fail "$id: expected $exp, got $got (raw=$r)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# L1: cd "<LINKED>" && gh pr create → findRepoRootForBash returns LINKED
# ─────────────────────────────────────────────────────────────────────────────
assert_root_eq "L1" "cd \"$LINKED_LITERAL\" && gh pr create" "$LINKED_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# L2: cd "<LINKED>" && git commit -m x → findRepoRootForBash returns LINKED
# ─────────────────────────────────────────────────────────────────────────────
assert_root_eq "L2" "cd \"$LINKED_LITERAL\" && git commit -m x" "$LINKED_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# L3: git -C "<LINKED>" status → returns LINKED (regression: -C path unchanged)
# ─────────────────────────────────────────────────────────────────────────────
assert_root_eq "L3" "git -C \"$LINKED_LITERAL\" status" "$LINKED_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# L4: plain gh command (no cd / no -C) → falls back to cwd repo (MAIN)
# ─────────────────────────────────────────────────────────────────────────────
assert_root_eq "L4" "gh issue create -t x" "$MAIN_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# L5: After setPayloadDerivedPaths([LINKED]), getSessionRepoRoots from MAIN
#     returns a set containing BOTH MAIN and LINKED.
# ─────────────────────────────────────────────────────────────────────────────
test_L5() {
    local r exp_main exp_linked low has_main has_linked
    r=$(
        cd "$MAIN" && run_with_timeout 30 node -e "
          try {
            const m = require('$HOOK');
            if (typeof m.setPayloadDerivedPaths !== 'function' ||
                typeof m.getSessionRepoRoots !== 'function') {
              console.log('NOT_EXPORTED'); process.exit(2);
            }
            m.setPayloadDerivedPaths([process.argv[1]]);
            const roots = m.getSessionRepoRoots();
            console.log(JSON.stringify([...roots].map(p => p.replace(/\\\\/g, '/'))));
          } catch(e) { console.log('ERROR: '+e.message); }
        " -- "$LINKED_LITERAL" 2>/dev/null
    )
    case "$r" in
        NOT_EXPORTED) fail "L5: setPayloadDerivedPaths/getSessionRepoRoots not exported"; return ;;
        ERROR*) fail "L5: $r"; return ;;
    esac
    exp_main="$(norm_path "$MAIN_NODE")"
    exp_linked="$(norm_path "$LINKED_NODE")"
    # Normalize the whole JSON-array output the same way as norm_path.
    low="$(echo "$r" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')"
    has_main=0; has_linked=0
    case "$low" in *"$exp_main"*) has_main=1 ;; esac
    case "$low" in *"$exp_linked"*) has_linked=1 ;; esac
    if [ "$has_main" = "1" ] && [ "$has_linked" = "1" ]; then
        pass "L5: payload-derived cache widens roots to {MAIN, LINKED}"
    else
        fail "L5: expected both MAIN ($exp_main) and LINKED ($exp_linked) in $r"
    fi
}
test_L5

# ─────────────────────────────────────────────────────────────────────────────
# L6: Without populating cache, getSessionRepoRoots from MAIN returns ONLY MAIN
#     (no broad expansion).
# ─────────────────────────────────────────────────────────────────────────────
test_L6() {
    local r exp_main exp_linked low has_main has_linked
    r=$(
        cd "$MAIN" && run_with_timeout 30 node -e "
          try {
            const m = require('$HOOK');
            if (typeof m.getSessionRepoRoots !== 'function') {
              console.log('NOT_EXPORTED'); process.exit(2);
            }
            // Reset cache if a setter exists so this test is independent.
            if (typeof m.setPayloadDerivedPaths === 'function') {
              m.setPayloadDerivedPaths([]);
            }
            const roots = m.getSessionRepoRoots();
            console.log(JSON.stringify([...roots].map(p => p.replace(/\\\\/g, '/'))));
          } catch(e) { console.log('ERROR: '+e.message); }
        " 2>/dev/null
    )
    case "$r" in
        NOT_EXPORTED) fail "L6: getSessionRepoRoots not exported"; return ;;
        ERROR*) fail "L6: $r"; return ;;
    esac
    exp_main="$(norm_path "$MAIN_NODE")"
    exp_linked="$(norm_path "$LINKED_NODE")"
    low="$(echo "$r" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')"
    has_main=0; has_linked=0
    case "$low" in *"$exp_main"*) has_main=1 ;; esac
    case "$low" in *"$exp_linked"*) has_linked=1 ;; esac
    if [ "$has_main" = "1" ] && [ "$has_linked" = "0" ]; then
        pass "L6: empty cache → roots contain only MAIN (no broad expansion)"
    else
        fail "L6: expected only MAIN; got main=$has_main linked=$has_linked raw=$r"
    fi
}
test_L6

# ─────────────────────────────────────────────────────────────────────────────
# L7: cd "$LINKED" && gh ... (literal $) → env-var rejected,
#     findRepoRootForBash falls back to cwd (MAIN).
# ─────────────────────────────────────────────────────────────────────────────
# Single-quoted bash string preserves the literal "$LINKED".
L7_CMD='cd "$LINKED" && gh pr create'
assert_root_eq "L7" "$L7_CMD" "$MAIN_NODE"

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

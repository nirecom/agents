#!/bin/bash
# Tests: hooks/enforce-worktree/config.js
# Tags: unit, enforce-worktree, deprecation, scope:common, pwsh-not-required
#
# Unit test: the ENFORCE_WORKTREE_EXCLUDE_REPOS → ENFORCE_WORKTREE_EXCLUDE migration
# in isRepoExcluded() is idempotent. The _EXCL_REPOS_MIGRATED env flag prevents
# double-appending the deprecated repos value into ENFORCE_WORKTREE_EXCLUDE when
# isRepoExcluded() is called more than once in the same process.
#
# L3 gap (what this unit test does NOT catch):
# - Real PreToolUse enforce-worktree hook session (hook process = this module)
# - Interaction with the OS-filter / load-env pipeline
# - Warning behavior across multiple hook invocations (each is a fresh process)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

MODULE_PATH="$_AGENTS_NODE/hooks/enforce-worktree/config.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

echo "=== config.js isRepoExcluded deprecation-migration tests ==="

# Driver: require config.js, call isRepoExcluded() twice with only EXCLUDE_REPOS set
# (EXCLUDE unset, _EXCL_REPOS_MIGRATED unset at process start). After both calls,
# ENFORCE_WORKTREE_EXCLUDE must contain the repos value exactly once —
# the _EXCL_REPOS_MIGRATED flag guards against a second append on the second call.
DRIVER='
const { isRepoExcluded } = require(process.argv[1]);
isRepoExcluded("/some/other/dir");
isRepoExcluded("/some/other/dir");
const val = process.env.ENFORCE_WORKTREE_EXCLUDE || "";
const count = val.split(";").filter(function(v) { return v.trim() === "/excluded/repo"; }).length;
process.stdout.write(count === 1 ? "no-dup" : "dup-found:" + count);'

got_rc=0
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
run_with_timeout 20 env \
    -u ENFORCE_WORKTREE_EXCLUDE \
    -u _EXCL_REPOS_MIGRATED \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=/excluded/repo" \
    node -e "$DRIVER" "$MODULE_PATH" \
    >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" || got_rc=$?

if grep -q "MODULE_NOT_FOUND\|Cannot find module" "$TMPBASE/stderr.txt" 2>/dev/null; then
    fail "exclude-repos-no-dup-migration — MODULE_NOT_FOUND ($MODULE_PATH)"
elif [ "$got_rc" != "0" ]; then
    fail "exclude-repos-no-dup-migration — node exited rc=$got_rc (stderr: $(cat "$TMPBASE/stderr.txt"))"
else
    result="$(cat "$TMPBASE/stdout.txt")"
    if [ "$result" = "no-dup" ]; then
        pass "exclude-repos-no-dup-migration — EXCLUDE_REPOS appended exactly once across two isRepoExcluded() calls"
    else
        fail "exclude-repos-no-dup-migration — want 'no-dup' got '$result'"
    fi
    # Also assert the deprecation warning is emitted exactly once across both calls.
    warn_count="$(grep -c "is deprecated" "$TMPBASE/stderr.txt" 2>/dev/null || echo 0)"
    if [ "$warn_count" = "1" ]; then
        pass "exclude-repos-warn-once — 'is deprecated' emitted exactly once across two isRepoExcluded() calls"
    else
        fail "exclude-repos-warn-once — want count=1 got count=$warn_count"
    fi
fi

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL

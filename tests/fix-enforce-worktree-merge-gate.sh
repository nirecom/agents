#!/bin/bash
# tests/fix-enforce-worktree-merge-gate.sh
# Tests: hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, bin, merge
# Unit tests for isAllowedFastForwardMerge() — added in fix/enforce-worktree-merge-gate.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
    else perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

ff_check() {
    run_with_timeout node -e "
      const { isAllowedFastForwardMerge } = require('$GUARD_JS');
      console.log(isAllowedFastForwardMerge(process.argv[1]) ? 'allow' : 'reject');
    " -- "$1" 2>/dev/null
}

assert_ff() {
    local desc="$1" cmd="$2" expected="$3"
    local got; got="$(ff_check "$cmd")"
    if [ "$got" = "$expected" ]; then pass "$desc -> $expected"
    else fail "$desc: expected '$expected', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

# Allowed
assert_ff "merge --ff-only origin/feature" 'git merge --ff-only origin/feature' "allow"
assert_ff "merge --ff-only (no upstream arg)" 'git merge --ff-only' "allow"
assert_ff "pull --ff-only" 'git pull --ff-only' "allow"
assert_ff "pull --ff-only origin main" 'git pull --ff-only origin main' "allow"
assert_ff "git -C path merge --ff-only" 'git -C /path merge --ff-only origin/feat' "allow"

# Rejected
assert_ff "plain merge" 'git merge feature' "reject"
assert_ff "merge --no-ff" 'git merge --no-ff feature' "reject"
assert_ff "chained ff-only && push" 'git merge --ff-only && git push' "reject"
assert_ff "non-git svn merge --ff-only" 'svn merge --ff-only' "reject"
assert_ff "git rebase --ff-only" 'git rebase --ff-only main' "reject"
assert_ff "merge --ff-only --no-ff (--no-ff overrides)" 'git merge --ff-only --no-ff feature' "reject"

# --- Security regression tests (post-review) ---

# Bypass attempt: literal "merge --ff-only" inside a -m message argument.
# The previous regex `(?:[^|;&]*\s)?` was loose enough to match this; the
# tightened `(?:-flag value? )*` form requires `merge` to be the subcommand.
assert_ff "git commit -m \"merge --ff-only\"" 'git commit -m "merge --ff-only"' "reject"

# Bypass attempt: `merge --ff-only` as a positional ref to another subcommand.
assert_ff "git push origin merge --ff-only" 'git push origin merge --ff-only' "reject"

# Bypass attempt: command substitution / backtick to smuggle an arbitrary
# command. hasShellChaining now also rejects $() and backticks.
assert_ff "merge --ff-only \$(rm -rf /)" 'git merge --ff-only $(rm -rf /)' "reject"
assert_ff "merge --ff-only with backticks" 'git merge --ff-only `echo origin/main`' "reject"
assert_ff "pull --ff-only with substitution" 'git pull --ff-only $(echo origin)' "reject"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL

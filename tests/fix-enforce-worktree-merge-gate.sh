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

# ─────────────────────────────────────────────────────────────────────────────
# Fix #820 — interpreter-wrapper hardening (rejectInterpreterAndChaining)
# These cases are RED until shared-cmd-utils.js exposes
# rejectInterpreterAndChaining and isAllowedFastForwardMerge calls it.
# ─────────────────────────────────────────────────────────────────────────────

assert_ff "bash -c 'git pull --ff-only' (interp wrapper)"           "bash -c 'git pull --ff-only'"            "reject"
assert_ff "bash -c 'git merge --ff-only' (interp wrapper)"          "bash -c 'git merge --ff-only'"           "reject"
assert_ff "/bin/bash -c 'git merge --ff-only' (path-qualified)"     "/bin/bash -c 'git merge --ff-only'"      "reject"
assert_ff "env bash -c 'git pull --ff-only' (launcher prefix)"      "env bash -c 'git pull --ff-only'"        "reject"

# ─────────────────────────────────────────────────────────────────────────────
# Fix #820 — RCE-flag hardening (rejectRceGitFlags)
# These cases are RED until isAllowedFastForwardMerge calls rejectRceGitFlags.
# Note: even the --receive-pack push form is rejected by the merge predicate
# because the predicate must refuse any cmd carrying RCE-class git flags,
# regardless of subcommand position.
# ─────────────────────────────────────────────────────────────────────────────

assert_ff "git -c core.sshCommand=curl pull --ff-only" 'git -c core.sshCommand=curl pull --ff-only' "reject"
assert_ff "git --upload-pack=cmd pull --ff-only"       'git --upload-pack=cmd pull --ff-only'       "reject"
assert_ff "git --receive-pack=cmd push (RCE flag)"     'git --receive-pack=cmd push'                "reject"

# Regression pin — these legitimate ff-only forms must still ALLOW after the
# helper guards are wired in. (Same cases as the original allow block but
# explicitly grouped post-#820 to make a regression in the new helper visible.)
assert_ff "regression: git pull --ff-only (post-#820)"               'git pull --ff-only'              "allow"
assert_ff "regression: git merge --ff-only main (post-#820)"         'git merge --ff-only main'        "allow"
assert_ff "regression: git pull --ff-only origin main (post-#820)"   'git pull --ff-only origin main'  "allow"

# ─────────────────────────────────────────────────────────────────────────────
# Class 1 — fd-dup I/O redirect fix (#1115, #982)
# POSIX I/O fd-dup redirects (2>&1, 1>&2, >&2) contain an unquoted `&` that
# hasShellChaining's `[|;&]` regex matches, so the chaining guard fires before
# the ff-only allow can apply. These are RED before the shared-cmd-utils.js fix
# sanitizes /\d*>&\d+|\d*>&-/g before the chaining test. &> / &>> (redirect-both)
# must NOT be sanitized — they remain blocked.
# ─────────────────────────────────────────────────────────────────────────────
assert_ff "merge --ff-only 2>&1 (fix #1115 — fd-dup must not block)" 'git merge --ff-only origin/main 2>&1' "allow"
assert_ff "pull --ff-only 2>&1 (fix #1115 — fd-dup must not block)" 'git pull --ff-only 2>&1' "allow"
assert_ff "merge --ff-only 1>&2 (fix #1115 — reverse fd-dup)" 'git merge --ff-only 1>&2' "allow"
assert_ff "merge --ff-only >&2 (fix #1115 — fd-dup form >&N)" 'git merge --ff-only >&2' "allow"
# Security regression pins — chaining and &> must remain blocked after the fix
assert_ff "merge --ff-only && push 2>&1 (chaining still blocked)" 'git merge --ff-only && git push 2>&1' "reject"
assert_ff "merge --ff-only &> /tmp/log (&> not sanitized, still blocked)" 'git merge --ff-only &> /tmp/log' "reject"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL

#!/bin/bash
# tests/fix-820-sibling-helper.sh
# Tests: hooks/enforce-worktree/shared-cmd-utils.js
# Tags: worktree, enforce, hook, security, fix-820, helper
#
# Direct unit tests for the two new sibling helper functions:
#   - rejectInterpreterAndChaining(cmd)
#   - rejectRceGitFlags(cmd)
#
# These helpers will be called by isAllowedFastForwardMerge,
# isAllowedPushAllExcluded, isAllowedMainWorktreeCleanup, and
# isAllowedWorktreeCommand to consolidate scattered inline checks for
# interpreter-prefix + shell-chaining patterns and RCE-flag injection.
#
# IMPORTANT: This test file is RED (fails) until source implementation
# adds these two helpers to shared-cmd-utils.js. The expected failure
# message is "rejectInterpreterAndChaining is not a function" or
# "rejectRceGitFlags is not a function". That is the expected RED state.
#
# Each test invokes the helper via inline node and exits 0 on REJECT
# (true) and 1 on ALLOW (false). The shell test then maps those into
# pass/fail according to the expected outcome.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
SHARED_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/shared-cmd-utils.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
    else perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Call rejectInterpreterAndChaining(cmd). Echoes "reject" or "allow".
# Echoes "ERROR" when the helper is missing (RED state before impl).
check_rejInterp() {
    run_with_timeout node -e "
      try {
        const { rejectInterpreterAndChaining } = require('$SHARED_JS');
        if (typeof rejectInterpreterAndChaining !== 'function') {
          console.log('ERROR'); process.exit(2);
        }
        console.log(rejectInterpreterAndChaining(process.argv[1]) ? 'reject' : 'allow');
      } catch (e) {
        console.log('ERROR'); process.exit(2);
      }
    " -- "$1" 2>/dev/null
}

# Call rejectRceGitFlags(cmd). Echoes "reject" or "allow".
check_rejRce() {
    run_with_timeout node -e "
      try {
        const { rejectRceGitFlags } = require('$SHARED_JS');
        if (typeof rejectRceGitFlags !== 'function') {
          console.log('ERROR'); process.exit(2);
        }
        console.log(rejectRceGitFlags(process.argv[1]) ? 'reject' : 'allow');
      } catch (e) {
        console.log('ERROR'); process.exit(2);
      }
    " -- "$1" 2>/dev/null
}

assert_interp_reject() {
    local desc="$1" cmd="$2"
    local got; got="$(check_rejInterp "$cmd")"
    if [ "$got" = "reject" ]; then pass "$desc -> reject"
    else fail "$desc: expected 'reject', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

assert_interp_allow() {
    local desc="$1" cmd="$2"
    local got; got="$(check_rejInterp "$cmd")"
    if [ "$got" = "allow" ]; then pass "$desc -> allow"
    else fail "$desc: expected 'allow', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

assert_rce_reject() {
    local desc="$1" cmd="$2"
    local got; got="$(check_rejRce "$cmd")"
    if [ "$got" = "reject" ]; then pass "$desc -> reject"
    else fail "$desc: expected 'reject', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

assert_rce_allow() {
    local desc="$1" cmd="$2"
    local got; got="$(check_rejRce "$cmd")"
    if [ "$got" = "allow" ]; then pass "$desc -> allow"
    else fail "$desc: expected 'allow', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# rejectInterpreterAndChaining(cmd) — REJECT cases (return true)
# ─────────────────────────────────────────────────────────────────────────────

assert_interp_reject "I1: plain bash -c"                        "bash -c 'git stash'"
assert_interp_reject "I2: /bin/bash -c (path-qualified)"        "/bin/bash -c 'git stash'"
assert_interp_reject "I3: UNC path \\\\wsl\$\\Ubuntu\\…\\bash" '\\wsl$\Ubuntu\usr\bin\bash -c "git stash"'
assert_interp_reject "I4: env bash -c (launcher prefix)"        "env bash -c 'git stash'"
assert_interp_reject "I5: sudo bash -c (launcher prefix)"       "sudo bash -c 'git stash'"
assert_interp_reject "I6: env sudo bash -c (chained launchers)" "env sudo bash -c 'git stash'"
assert_interp_reject "I7: my_var=foo bash -c (lowercase env)"   "my_var=foo bash -c 'git stash'"
assert_interp_reject "I8: MY_VAR=foo bash -c (uppercase env)"   "MY_VAR=foo bash -c 'git stash'"

# Literal newline (stripped form contains a newline operator).
NL_CMD="$(printf 'git stash\nrm -rf /')"
assert_interp_reject "I9: literal newline in cmd"               "$NL_CMD"

# Process substitution: <(…) — bash extension that spawns a shell.
assert_interp_reject "I10: process substitution <(cat /etc/passwd)" "git stash <(cat /etc/passwd)"

# ─────────────────────────────────────────────────────────────────────────────
# rejectInterpreterAndChaining(cmd) — ALLOW cases (return false)
# ─────────────────────────────────────────────────────────────────────────────

assert_interp_allow "I20: plain git stash"                      "git stash push"
assert_interp_allow "I21: git merge --ff-only"                  "git merge --ff-only main"
assert_interp_allow "I22: git push origin main"                 "git push origin main"
assert_interp_allow "I23: git -C /bin/bash stash (path arg)"    "git -C /bin/bash stash"
assert_interp_allow "I24: sudo git push (sudo + git, not interp)" "sudo git push"
assert_interp_allow "I25: env git merge (env + git, not interp)" "env git merge"
assert_interp_allow "I26: foo=bar git push (env prefix + git)"  "foo=bar git push"

# ─────────────────────────────────────────────────────────────────────────────
# rejectRceGitFlags(cmd) — REJECT cases (return true)
# ─────────────────────────────────────────────────────────────────────────────

assert_rce_reject "R1: git -c core.sshCommand=curl pull --ff-only" "git -c core.sshCommand=curl pull --ff-only"
assert_rce_reject "R2: git -c core.sshCommand=evil push"           "git -c core.sshCommand=evil push"
assert_rce_reject "R3: git --upload-pack=cmd push"                 "git --upload-pack=cmd push"
assert_rce_reject "R4: git --upload-pack cmd push (space form)"    "git --upload-pack cmd push"
assert_rce_reject "R5: git --receive-pack=cmd push"                "git --receive-pack=cmd push"
assert_rce_reject "R6: git --receive-pack cmd push (space form)"   "git --receive-pack cmd push"

# ─────────────────────────────────────────────────────────────────────────────
# rejectRceGitFlags(cmd) — ALLOW cases (return false)
# ─────────────────────────────────────────────────────────────────────────────

assert_rce_allow "R20: git push"                                "git push"
assert_rce_allow "R21: git pull --ff-only"                      "git pull --ff-only"
assert_rce_allow "R22: git merge --ff-only main"                "git merge --ff-only main"
assert_rce_allow "R23: git stash push (word 'push' as subcmd)"  "git stash push"
assert_rce_allow "R24: git -C /repo push (-C is path, not -c)"  "git -C /repo push"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "NOTE: This test file is EXPECTED to be RED until source"
    echo "implementation adds rejectInterpreterAndChaining and"
    echo "rejectRceGitFlags to hooks/enforce-worktree/shared-cmd-utils.js."
fi
exit $FAIL

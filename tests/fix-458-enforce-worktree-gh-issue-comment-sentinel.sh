#!/bin/bash
# tests/fix-458-enforce-worktree-gh-issue-comment-sentinel.sh
# Tests: hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, redirect, shell-expansion, gh, sentinel
#
# Regression pins for issue #458: `gh issue comment` (Group A coordination
# command that touches GitHub metadata only) must classify as "read", even
# when the body contains a sentinel-shaped comment.  The pins guard against
# future regressions of the Group A read-classification — they should be
# GREEN today and must stay GREEN after the #793 expandStaticShellTokens
# implementation lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"
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
        "$@"
    fi
}

# Invoke classify(cmd) and emit its string result.
call_classify() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.classify(process.argv[1]);
        console.log(r);
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit pins — classify() on `gh issue comment` variants
# ─────────────────────────────────────────────────────────────────────────────

test_case_a_plain_gh_issue_comment_sentinel_body() {
    # Case A: plain `gh issue comment` with a sentinel-shaped body comment
    # must classify as "read" (Group A coordination → no file write).
    assert_fn_result 'classify: gh issue comment with sentinel body → read' \
        "$(call_classify 'gh issue comment 123 --body "<!-- issue-close-sentinel: appended -->"')" \
        'read'
}

test_case_b_env_prefix_gh_issue_comment() {
    # Case B: ISSUE_CLOSE_SKILL=1 inline env-prefix form.  classify() sees
    # the whole string including the env-prefix; pinning current behavior so
    # any regression surfaces.
    assert_fn_result 'classify: ISSUE_CLOSE_SKILL=1 gh issue comment → read' \
        "$(call_classify 'ISSUE_CLOSE_SKILL=1 gh issue comment 123 --body "<!-- issue-close-sentinel: appended -->"')" \
        'read'
}

test_case_c_arbitrary_body() {
    # Case C: arbitrary body text (not sentinel-shaped) — Group A regex
    # matches `gh issue comment` regardless of body content.
    assert_fn_result 'classify: gh issue comment with arbitrary body → read' \
        "$(call_classify 'gh issue comment 456 --body "some arbitrary body text"')" \
        'read'
}

# ─────────────────────────────────────────────────────────────────────────────
# Integration pin — enforce-worktree.js end-to-end on a sequenced command
# ─────────────────────────────────────────────────────────────────────────────
#
# Case D: `echo x && gh issue comment ...` — both segments classify as read,
# so the whole command is "read" and the hook short-circuits to {} (allow).
# This is the current observed behavior; the pin guards against a regression
# where the && sequencing operator accidentally lifts the command to "write"
# without a real write target.

test_case_d_echo_and_gh_issue_comment_integration() {
    local stdin_json got
    stdin_json='{"tool_name":"Bash","tool_input":{"command":"echo x && gh issue comment 123 --body \"hello\""},"session_id":"test-session-458"}'
    got="$( \
        echo "$stdin_json" | \
        ENFORCE_WORKTREE=on CLAUDE_SESSION_ID=test-session-458 \
        run_with_timeout 30 node "$HOOK" 2>/dev/null)"
    if [ "$got" = "{}" ]; then
        pass "integration: 'echo x && gh issue comment ...' → '{}' (read, allow)"
    else
        fail "integration: 'echo x && gh issue comment ...' expected '{}', got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_case_a_plain_gh_issue_comment_sentinel_body
test_case_b_env_prefix_gh_issue_comment
test_case_c_arbitrary_body
test_case_d_echo_and_gh_issue_comment_integration

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi

#!/bin/bash
# Tests: hooks/enforce-issue-close.js, hooks/lib/block-predicates.js, rules/github-issues.md, bin/github-issues/close-completed.sh, agents/issue-close-finalize-worker.md
# Tags: enforce-issue-close, block-predicates, inline-skill-re, close-completed, icf-worker, scope:issue-specific
# Tests for issue #927 — INLINE_SKILL_RE removal. After the change, the ONLY
# bypass for a direct Bash-tool `gh issue close` is the env-export form
# (ISSUE_CLOSE_SKILL=1 in process.env). The inline prefix shape
# `ISSUE_CLOSE_SKILL=1 gh issue close N --reason completed` is now BLOCKED.
# F13-F20 cover the close-completed.sh script and ICF-H change.
#
# L3 gap (what this test does NOT catch):
# - Whether the hook registration in settings.json actually fires in a real Claude Code session
# - Whether the block message renders in a real Claude Code terminal output
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/enforce-issue-close.js"
PREDICATES="$AGENTS_DIR/hooks/lib/block-predicates.js"
PREDICATES_NODE="$_AGENTS_DIR_NODE/hooks/lib/block-predicates.js"
RULES="$AGENTS_DIR/rules/github-issues.md"
CLOSE_COMPLETED="$AGENTS_DIR/bin/github-issues/close-completed.sh"
ICF_WORKER="$AGENTS_DIR/agents/issue-close-finalize-worker.md"

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

if [ ! -f "$HOOK" ]; then
    echo "FAIL: precondition missing — hooks/enforce-issue-close.js"
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# run_hook variants: stdin JSON, ISSUE_CLOSE_SKILL env state controlled per call.
run_hook_no_env() {
    local json="$1"
    OUT=$(
        unset ISSUE_CLOSE_SKILL
        echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.fix927_hook_err.$$
    )
    RC=$?
    ERR=$(cat /tmp/.fix927_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.fix927_hook_err.$$
}

run_hook_skilled() {
    local json="$1"
    OUT=$(echo "$json" | ISSUE_CLOSE_SKILL=1 run_with_timeout 15 node "$HOOK" 2>/tmp/.fix927_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.fix927_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.fix927_hook_err.$$
}

# ============================================================================
# F1: block-predicates.js does NOT export INLINE_SKILL_RE
# ============================================================================
if [ ! -f "$PREDICATES" ]; then
    skip "F1: block-predicates.js not present"
else
    OUT=$(run_with_timeout 5 node -e "
const m = require('$PREDICATES_NODE');
if (typeof m.INLINE_SKILL_RE === 'undefined') {
    console.log('OK');
} else {
    console.error('INLINE_SKILL_RE still exported: ' + String(m.INLINE_SKILL_RE));
    process.exit(1);
}
" 2>&1)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "OK" ]; then
        pass "F1: block-predicates.js does NOT export INLINE_SKILL_RE"
    else
        fail "F1: INLINE_SKILL_RE still present (rc=$RC out=$OUT)"
    fi
fi

# ============================================================================
# F2: enforce-issue-close.js source text does NOT contain INLINE_SKILL_RE
# ============================================================================
if grep -q "INLINE_SKILL_RE" "$HOOK" 2>/dev/null; then
    fail "F2: enforce-issue-close.js still references INLINE_SKILL_RE"
else
    pass "F2: enforce-issue-close.js no longer references INLINE_SKILL_RE"
fi

# ============================================================================
# F3: inline ISSUE_CLOSE_SKILL=1 ... --reason completed (no env) → BLOCKED
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed"}}'
if [ "$RC" -eq 2 ]; then
    pass "F3: inline ISSUE_CLOSE_SKILL=1 --reason completed is BLOCKED"
else
    fail "F3: expected exit 2 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F4: inline with --reason not_planned (no env) → BLOCKED
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason not_planned"}}'
if [ "$RC" -eq 2 ]; then
    pass "F4: inline --reason not_planned is BLOCKED"
else
    fail "F4: expected exit 2 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F5: segment-separator with inline ISSUE_CLOSE_SKILL=1 → BLOCKED
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && ISSUE_CLOSE_SKILL=1 gh issue close 897 --reason completed"}}'
if [ "$RC" -eq 2 ]; then
    pass "F5: 'cd /tmp && ISSUE_CLOSE_SKILL=1 gh issue close ...' is BLOCKED"
else
    fail "F5: expected exit 2 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F6: inline with quoted issue number → BLOCKED
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close \"897\" --reason completed"}}'
if [ "$RC" -eq 2 ]; then
    pass "F6: inline with quoted issue number is BLOCKED"
else
    fail "F6: expected exit 2 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F7: env-export ISSUE_CLOSE_SKILL=1 approves any gh issue close
# ============================================================================
run_hook_skilled '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 0 ]; then
    pass "F7: env-export ISSUE_CLOSE_SKILL=1 approves 'gh issue close 123'"
else
    fail "F7: expected exit 0 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F8: env-export ISSUE_CLOSE_SKILL=1 approves --reason not_planned
# ============================================================================
run_hook_skilled '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123 --reason not_planned"}}'
if [ "$RC" -eq 0 ]; then
    pass "F8: env-export approves 'gh issue close 123 --reason not_planned'"
else
    fail "F8: expected exit 0 (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F9: block message for --reason not_planned mentions /issue-close-migrated
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123 --reason not_planned"}}'
if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q "issue-close-migrated"; then
    pass "F9: block message for --reason not_planned mentions /issue-close-migrated"
else
    fail "F9: expected exit 2 + stderr to mention issue-close-migrated (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F10: block message for bare close mentions /issue-close-finalize
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q "issue-close-finalize"; then
    pass "F10: block message for bare close mentions /issue-close-finalize"
else
    fail "F10: expected exit 2 + stderr to mention issue-close-finalize (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F11: rules/github-issues.md does NOT contain "Two forms are accepted:"
# Soft assertion — skip if file unmodified (TDD red phase).
# ============================================================================
if [ ! -f "$RULES" ]; then
    skip "F11: rules/github-issues.md not present"
elif grep -q "Two forms are accepted" "$RULES" 2>/dev/null; then
    fail "F11: rules/github-issues.md still contains 'Two forms are accepted:'"
else
    pass "F11: rules/github-issues.md no longer contains 'Two forms are accepted:'"
fi

# ============================================================================
# F12: non-Bash tool invocation (Read tool) → approved (exit 0)
# Only the Bash tool is gated by enforce-issue-close.js.
# ============================================================================
run_hook_no_env '{"tool_name":"Read","tool_input":{"file_path":"/foo/bar"}}'
if [ "$RC" -eq 0 ]; then
    pass "F12: non-Bash tool (Read) is approved (exit 0)"
else
    fail "F12: expected exit 0 for Read tool (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F13: close-completed.sh exists and is executable
# TDD red phase — will FAIL until bin/github-issues/close-completed.sh is created.
# ============================================================================
if [ -f "$CLOSE_COMPLETED" ] && [ -x "$CLOSE_COMPLETED" ]; then
    pass "F13: close-completed.sh exists and is executable"
else
    fail "F13: close-completed.sh missing or not executable (path=$CLOSE_COMPLETED)"
fi

# ============================================================================
# F14: close-completed.sh contains --repo flag handling
# TDD red phase — will FAIL until the file is created with --repo support.
# ============================================================================
if [ ! -f "$CLOSE_COMPLETED" ]; then
    fail "F14: close-completed.sh missing — cannot check --repo flag handling"
elif grep -q "\-\-repo" "$CLOSE_COMPLETED" 2>/dev/null; then
    pass "F14: close-completed.sh contains --repo flag handling"
else
    fail "F14: close-completed.sh does not contain --repo flag handling"
fi

# ============================================================================
# F15: bash .../close-completed.sh N is NOT blocked by enforce-issue-close.js
# The command head is 'bash', not 'gh', so the hook passes it through.
# This should PASS regardless of whether close-completed.sh exists.
# ============================================================================
run_hook_no_env "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash $CLOSE_COMPLETED 123\"}}"
if [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; then
    pass "F15: 'bash close-completed.sh 123' is NOT blocked by enforce-issue-close.js (rc=$RC)"
else
    fail "F15: expected rc 0 or 1 (not 2) for bash-headed command (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F16: raw 'gh issue close N' is still blocked (regression guard)
# ============================================================================
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"gh issue close 999"}}'
if [ "$RC" -eq 2 ]; then
    pass "F16: raw 'gh issue close 999' is still blocked (regression guard)"
else
    fail "F16: expected exit 2 for raw gh issue close (rc=$RC stderr=$ERR)"
fi

# ============================================================================
# F17: issue-close-finalize-worker.md ICF-H calls close-completed.sh with --repo
# TDD red phase — will FAIL until ICF-H is updated to use close-completed.sh.
# ============================================================================
if [ ! -f "$ICF_WORKER" ]; then
    skip "F17: agents/issue-close-finalize-worker.md not present"
elif grep -q "close-completed.sh" "$ICF_WORKER" 2>/dev/null && grep -q "\-\-repo" "$ICF_WORKER" 2>/dev/null; then
    pass "F17: ICF-H calls close-completed.sh with --repo argument"
else
    fail "F17: ICF-H does not call close-completed.sh with --repo (file may still use ISSUE_CLOSE_SKILL=1 gh issue close)"
fi

# ============================================================================
# F18: issue-close-finalize-worker.md ICF-H does NOT contain ISSUE_CLOSE_SKILL=1 gh issue close
# TDD red phase — will FAIL until ICF-H is updated.
# ============================================================================
if [ ! -f "$ICF_WORKER" ]; then
    skip "F18: agents/issue-close-finalize-worker.md not present"
elif grep -q "ISSUE_CLOSE_SKILL=1 gh issue close" "$ICF_WORKER" 2>/dev/null; then
    fail "F18: ICF-H still contains 'ISSUE_CLOSE_SKILL=1 gh issue close'"
else
    pass "F18: ICF-H does NOT contain 'ISSUE_CLOSE_SKILL=1 gh issue close'"
fi

# ============================================================================
# F19: rules/github-issues.md no longer describes env-export as "sole sanctioned bypass form"
# TDD red phase — will FAIL until rules/github-issues.md is updated.
# ============================================================================
if [ ! -f "$RULES" ]; then
    skip "F19: rules/github-issues.md not present"
elif grep -q "Sole sanctioned bypass form" "$RULES" 2>/dev/null; then
    fail "F19: rules/github-issues.md still says 'Sole sanctioned bypass form'"
else
    pass "F19: rules/github-issues.md no longer says 'Sole sanctioned bypass form'"
fi

# ============================================================================
# F20: hooks/enforce-issue-close.js header no longer claims /issue-close-finalize
#      sets ISSUE_CLOSE_SKILL=1
# TDD red phase — will FAIL until the header comment is updated.
# ============================================================================
if grep -q "sets ISSUE_CLOSE_SKILL=1" "$HOOK" 2>/dev/null; then
    fail "F20: enforce-issue-close.js header still claims '/issue-close-finalize sets ISSUE_CLOSE_SKILL=1'"
else
    pass "F20: enforce-issue-close.js header no longer claims 'sets ISSUE_CLOSE_SKILL=1'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

#!/usr/bin/env bash
# tests/feature-supervisor-silent-no-finding.sh
# Tests: hooks/supervisor-guard.js
# Tags: supervisor, em-supervisor, stop, silent, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - hooks/supervisor-guard.js firing as a real Claude Code Stop hook in a live session
#   (settings.json Stop hook registration — verified only via live claude -p run)
# - Real transcript JSONL format differences from the minimal crafted input used here
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T1: no-finding supervisor state → supervisor-guard.js → exit 0 AND empty stdout
# Asserts Change 1 + branch(4) removal: warning/notice advisory is gone; falls
# through to branch (5) silently.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr1'; }

if [ ! -f "$HOOK" ]; then
    skip "T1: supervisor-guard.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- T1a: state with no findings, cumSev=null → exit 0 + empty stdout ---
run_t1a() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t1a-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
// No findings, no cumSev — bare empty state
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T1a: exit code should be 0, got $rc"
        return
    fi
    if [ -n "$out" ]; then
        fail "T1a: stdout should be empty for no-finding state, got: $(printf '%q' "$out")"
        return
    fi
    pass "T1a: no-finding state → exit 0, empty stdout"
}

# --- T1b: state with cumSev=warning, zero alert findings → exit 0 + NO advisory in stdout ---
# This specifically tests that branch(4) advisory is gone after Change 1.
# After the change, warning cumSev with no armed alert should fall through to (5) silently.
run_t1b() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t1b-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.cumulative_severity = 'warning';
st.alert.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'test finding',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T1b: exit code should be 0, got $rc"
        return
    fi
    # After Change 1: branch(4) advisory removed — stdout must be empty.
    # Before Change 1 (current code): stdout contains additionalContext advisory.
    # This test is RED until branch(4) is removed.
    if echo "$out" | grep -q "additionalContext"; then
        fail "T1b: stdout must NOT contain additionalContext advisory for warning cumSev (branch(4) not yet removed)"
        return
    fi
    if [ -n "$out" ]; then
        fail "T1b: stdout should be empty after branch(4) removal, got: $(printf '%q' "$out")"
        return
    fi
    pass "T1b: warning cumSev + no alert armed → exit 0, empty stdout (branch(4) advisory removed)"
}


# --- T1c: transcript with OFF proposal → no decision:block (Change 4 C3 branch regression) ---
# RED-EXPECTED until Change 4 removes the C3 block branch from supervisor-guard.js.
# Current code: detectOffProposal returns detected=true → decision:"block" emitted.
# After Change 4: C3 Stop-hook block branch removed; OFF proposals handled by PreToolUse shim.
run_t1c() {
    local tmp sid out rc transcript_file
    tmp=$(make_tmp)
    sid="t1c-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi
    transcript_file="$tmp_node/transcript-t1c.jsonl"

    # Seed empty state
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Create JSONL transcript: assistant Bash tool_use with WORKTREE_OFF sentinel
    run_with_timeout 5 node -e "
const fs = require('fs');
const line = JSON.stringify({
    type: 'assistant',
    message: {
        content: [{
            type: 'tool_use',
            name: 'Bash',
            input: { command: 'echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"' }
        }]
    }
});
fs.writeFileSync('$transcript_file', line + '\n');
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$transcript_file")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # After Change 4: no decision:block in stdout (C3 branch removed).
    # Before Change 4 (current code): stdout contains decision:block → test FAILS (RED-EXPECTED).
    if echo "$out" | grep -q '"decision"'; then
        fail "T1c: OFF proposal in transcript → decision:block was emitted (C3 branch not yet removed)"
        return
    fi
    pass "T1c: OFF proposal in transcript → no decision:block emitted (C3 branch removed)"
}

run_t1a
run_t1b
run_t1c

# Additional-2: AskUserQuestion gate suppression
# When the last assistant turn ends with AskUserQuestion, branches (2) and (3) are suppressed.
# Condition: alert_armed_at set (would normally trigger branch 3) + transcript ending with AskUserQuestion.
# Expected: hook exits 0 silently (no block, no AskUserQuestion block on top).
run_additional2_ask_user_question_gate() {
    local tmp sid tmp_node transcript_file hook_input out rc
    tmp=$(make_tmp)
    sid="add2-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi
    transcript_file="$tmp_node/transcript-add2.jsonl"

    # Seed state: alert_armed_at set (would normally trigger branch 3 block)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.alert_armed_at = new Date().toISOString();
st.alert.cumulative_severity = 'warning';
st.alert.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'armed alert for ask-user-question test',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Create transcript: last assistant turn ends with AskUserQuestion tool_use
    run_with_timeout 5 node -e "
const fs = require('fs');
const line = JSON.stringify({
    type: 'assistant',
    message: {
        content: [
            { type: 'text', text: 'What would you like to do?' },
            { type: 'tool_use', name: 'AskUserQuestion', id: 'tu_1', input: { question: 'Proceed?' } }
        ]
    }
});
fs.writeFileSync('$transcript_file', line + '\n');
" >/dev/null 2>&1

    hook_input=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$transcript_file")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # With AskUserQuestion as last tool_use, branch (3) must be suppressed → exit 0, no block
    if [ $rc -ne 0 ]; then
        fail "Additional-2: AskUserQuestion gate — hook must exit 0, got rc=$rc"
        return
    fi
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "Additional-2: AskUserQuestion gate — hook must NOT block when last tool_use is AskUserQuestion, got: $(printf '%q' "${out:0:80}")"
        return
    fi
    pass "Additional-2: AskUserQuestion gate — alert_armed_at + AskUserQuestion last turn → branch (3) suppressed, exit 0"
}
run_additional2_ask_user_question_gate

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

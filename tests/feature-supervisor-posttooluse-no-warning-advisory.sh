#!/usr/bin/env bash
# tests/feature-supervisor-posttooluse-no-warning-advisory.sh
# Tests: hooks/supervisor-trigger.js
# Tags: supervisor, em-supervisor, posttooluse, advisory, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - supervisor-trigger.js firing as a real PostToolUse hook in a live session
#   (settings.json PostToolUse registration — verified only via live claude -p run)
# - Real Claude Code JSONL transcript format differences
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T2: state with cumulative_severity="warning" → invoke supervisor-trigger.js via stdin
# → assert stdout contains NO `additionalContext` field (Change 1: warning/notice
#   PostToolUse advisory fully removed; only cumSev==="error" advises).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-trigger.js"
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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr2'; }

if [ ! -f "$HOOK" ]; then
    skip "T2: supervisor-trigger.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- T2a: cumSev=warning → no additionalContext in stdout ---
run_t2a() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t2a-sid-$$"
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
    detail: 'test warning finding',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"echo hello"},"tool_response":{"output":"hello"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # Change 1: warning advisory removed — must NOT contain additionalContext
    if echo "$out" | grep -q "additionalContext"; then
        fail "T2a: cumSev=warning must NOT produce additionalContext in PostToolUse (warning advisory not yet removed)"
        return
    fi
    pass "T2a: cumSev=warning → no additionalContext in PostToolUse stdout"
}

# --- T2b: cumSev=notice → no additionalContext in stdout ---
run_t2b() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t2b-sid-$$"
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
st.alert.cumulative_severity = 'notice';
st.alert.findings = [{
    categories: ['other'],
    severity: 'notice',
    detail: 'notice finding',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"echo hello"},"tool_response":{"output":"hello"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if echo "$out" | grep -q "additionalContext"; then
        fail "T2b: cumSev=notice must NOT produce additionalContext in PostToolUse (notice advisory not yet removed)"
        return
    fi
    pass "T2b: cumSev=notice → no additionalContext in PostToolUse stdout"
}

# --- T2c: cumSev=error → additionalContext IS present (error advisory must remain) ---
run_t2c() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t2c-sid-$$"
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
st.alert.cumulative_severity = 'error';
st.alert.findings = [{
    categories: ['workflow'],
    severity: 'error',
    detail: 'error finding',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"echo hello"},"tool_response":{"output":"hello"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # error advisory must remain (this is a negative-control sanity check)
    if ! echo "$out" | grep -q "additionalContext"; then
        fail "T2c: cumSev=error MUST produce additionalContext (error advisory should still exist)"
        return
    fi
    pass "T2c: cumSev=error → additionalContext present (error advisory preserved)"
}


# --- T2d: OFF sentinel + blocking layer1 finding → alert_armed_at must NOT be set (Change 4 regression) ---
# RED-EXPECTED until Change 4 removes the C2 arm path from supervisor-trigger.js.
# Current code: isEscapeHatch && !alertArmedAt && hasBlockingFinding → alert_armed_at set.
# After Change 4: the arm path is removed; OFF commands no longer arm alert_armed_at here.
run_t2d() {
    local tmp sid armed_at state_path state_json
    tmp=$(make_tmp)
    sid="t2d-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # Seed: layer1 blocking finding (severity=warning) + alert_armed_at=null (default)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer1.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'workflow-gate blocking finding',
    reporter: 'workflow-gate',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"echo \\"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\\""},"tool_response":{"output":""}}' "$sid")

    # Snapshot state before hook invocation (C3: no-mutation baseline)
    state_path="$tmp/${sid}-supervisor-state.json"
    state_before=$(cat "$state_path" 2>/dev/null || echo "{}")

    WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" >/dev/null 2>&1

    state_after=$(cat "$state_path" 2>/dev/null || echo "{}")
    rm -rf "$tmp"

    # C3: assert no state mutation (alert_armed_at, alert_phase, audit_phase, l1.findings count)
    mutation_errs=$(node -e "
const b=JSON.parse(process.argv[1]||'{}'), a=JSON.parse(process.argv[2]||'{}');
const e=[];
if (a.alert&&a.alert.alert_armed_at) e.push('alert_armed_at set');
if ((b.alert&&b.alert.alert_phase)!==(a.alert&&a.alert.alert_phase)) e.push('alert_phase changed');
if ((b.audit&&b.audit.audit_phase)!==(a.audit&&a.audit.audit_phase)) e.push('audit_phase changed');
const bl=(b.layer1&&b.layer1.findings&&b.layer1.findings.length)||0;
const al=(a.layer1&&a.layer1.findings&&a.layer1.findings.length)||0;
if (bl!==al) e.push('l1.findings: '+bl+' -> '+al);
process.stdout.write(e.length?e.join('; '):'ok');
" -- "$state_before" "$state_after" 2>/dev/null || echo "node-error")

    if [ "$mutation_errs" != "ok" ]; then
        fail "T2d: supervisor state mutated by OFF sentinel + blocking layer1: $mutation_errs"
        return
    fi
    pass "T2d: OFF sentinel + blocking layer1 → all state unchanged (C3: armed_at null, alert/audit_phase, l1.findings unmodified)"
}

run_t2a
run_t2b
run_t2c
run_t2d

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

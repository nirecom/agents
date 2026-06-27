#!/bin/bash
# tests/fix-891-l2-phase-guard-cli.sh
# Tests: hooks/supervisor-guard.js, bin/supervisor-write-alert, hooks/lib/workflow-state.js
# Tags: supervisor, em-supervisor, layer2, l2-phase, stop, guard, cli
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks
# - real Claude Code transcript format differences
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
CLI="$AGENTS_DIR/bin/supervisor-write-alert"
CLI_NODE="$_AGENTS_DIR_NODE/bin/supervisor-write-alert"
MARK_STEP_HANDLER="$AGENTS_DIR/hooks/workflow-mark/mark-step-handler.js"
MARK_STEP_HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/mark-step-handler.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

seed_state_raw() {
    local tmp="$1" sid="$2" alert_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const now = new Date().toISOString();
const st = {
  version: 1,
  session_id: '$sid',
  created_at: now,
  last_updated: now,
  layer1: { findings: [] },
  alert: $alert_json,
  audit: {},
};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

make_fixture() {
    local path="$1"; shift
    for line in "$@"; do printf '%s\n' "$line"; done > "$path"
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

read_alert_phase() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
try {
  const raw = fs.readFileSync(w.getStatePath('$sid'), 'utf8');
  const st = JSON.parse(raw);
  const v = st && st.alert ? st.alert.alert_phase : undefined;
  process.stdout.write(v === undefined ? 'undefined' : (v === null ? 'null' : String(v)));
} catch (e) {
  process.stdout.write('error:' + e.message);
}
" 2>/dev/null
}

# ─── CLI tests (G34–G37) ─────────────────────────────────────────────────────

run_g34() {
    require_source "$CLI" "G34: CLI --set-alert-phase done -> state has alert_phase done" || return
    local tmp rc phase
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g34-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: null }"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" --session-id g34-sid --set-alert-phase done >/dev/null 2>&1
    rc=$?
    phase=$(read_alert_phase "$tmp" "g34-sid")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$phase" = "done" ]; then
        pass "G34: CLI --set-alert-phase done -> state has alert_phase done"
    else
        fail "G34: CLI --set-alert-phase done -> state has alert_phase done (rc=$rc, phase=$phase)"
    fi
}

run_g35() {
    require_source "$CLI" "G35: CLI --set-alert-phase invalid -> exit 1" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" --session-id g35-sid --set-alert-phase bogus >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 1 ]; then
        pass "G35: CLI --set-alert-phase invalid -> exit 1"
    else
        fail "G35: CLI --set-alert-phase invalid -> exit 1 (rc=$rc)"
    fi
}

run_g36() {
    require_source "$CLI" "G36: CLI --set-alert-phase alone -> succeeds" || return
    local tmp rc phase
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" --session-id g36-sid --set-alert-phase pending >/dev/null 2>&1
    rc=$?
    phase=$(read_alert_phase "$tmp" "g36-sid")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$phase" = "pending" ]; then
        pass "G36: CLI --set-alert-phase alone -> succeeds"
    else
        fail "G36: CLI --set-alert-phase alone -> succeeds (rc=$rc, phase=$phase)"
    fi
}

run_g37() {
    require_source "$CLI" "G37: CLI --set-alert-phase frozen + --l2-armed-at -> exit 1" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" --session-id g37-sid --set-alert-phase frozen --l2-armed-at "2026-06-06T12:00:00Z" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 1 ]; then
        pass "G37: CLI --set-alert-phase frozen + --l2-armed-at -> exit 1"
    else
        fail "G37: CLI --set-alert-phase frozen + --l2-armed-at -> exit 1 (rc=$rc)"
    fi
}

# ─── Guard tests (G38–G43) ───────────────────────────────────────────────────

run_g38() {
    require_source "$HOOK" "G38: alert_phase=frozen + alert_armed_at non-null -> exit 0 no block" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g38-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'frozen' }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g38-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G38: alert_phase=frozen + alert_armed_at non-null -> exit 0 no block"
    else
        fail "G38: alert_phase=frozen + alert_armed_at non-null -> exit 0 no block (rc=$rc, out=$out)"
    fi
}

run_g39() {
    require_source "$HOOK" "G39: alert_phase=frozen + final_report sentinel as last tool_use -> exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state_raw "$tmp" "g39-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'frozen' }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g39-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G39: alert_phase=frozen + final_report sentinel as last tool_use -> exit 0"
    else
        fail "G39: alert_phase=frozen + final_report sentinel as last tool_use -> exit 0 (rc=$rc, out=$out)"
    fi
}

run_g40() {
    require_source "$HOOK" "G40: alert_phase=frozen + write_code sentinel as last tool_use -> exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state_raw "$tmp" "g40-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'frozen' }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g40-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G40: alert_phase=frozen + write_code sentinel as last tool_use -> exit 0"
    else
        fail "G40: alert_phase=frozen + write_code sentinel as last tool_use -> exit 0 (rc=$rc, out=$out)"
    fi
}

run_g41() {
    require_source "$HOOK" "G41: alert_phase=done + no triggers -> exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g41-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'done' }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g41-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G41: alert_phase=done + no triggers -> exit 0"
    else
        fail "G41: alert_phase=done + no triggers -> exit 0 (rc=$rc, out=$out)"
    fi
}

run_g42() {
    require_source "$HOOK" "G42: alert_phase=null + final_report sentinel only -> exit 0 (exempt)" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state_raw "$tmp" "g42-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: null }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g42-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G42: alert_phase=null + final_report sentinel only -> exit 0 (exempt)"
    else
        fail "G42: alert_phase=null + final_report sentinel only -> exit 0 (exempt) (rc=$rc, out=$out)"
    fi
}

run_g43() {
    require_source "$HOOK" "G43: alert_phase=pending + alert_armed_at + final_report sentinel only -> exit 2 (C2 fires)" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state_raw "$tmp" "g43-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'pending' }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g43-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "G43: alert_phase=pending + alert_armed_at + final_report sentinel only -> exit 2 (C2 fires)"
    else
        fail "G43: alert_phase=pending + alert_armed_at + final_report sentinel only -> exit 2 (C2 fires) (rc=$rc, out=$out)"
    fi
}

# ─── VALID_STEPS test (G44) ──────────────────────────────────────────────────

run_g44() {
    require_source "$MARK_STEP_HANDLER" "G44: mark-step-handler with pre_final_report_gate -> no unknown-step warning" || return
    local out
    out=$(run_with_timeout 5 node -e "
const h = require('$MARK_STEP_HANDLER_NODE');
const messages = [];
let fatal = null;
const ctx = {
  cmd: 'echo \"<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>\"',
  sessionId: 'g44-sid',
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { fatal = m; },
};
process.env.CLAUDE_WORKFLOW_DIR = require('os').tmpdir();
const handled = h.handle(ctx);
const unknown = messages.some((m) => /unknown step/.test(m));
process.stdout.write(unknown ? 'unknown' : 'recognized');
" 2>/dev/null)
    if [ "$out" = "recognized" ]; then
        pass "G44: mark-step-handler with pre_final_report_gate -> no unknown-step warning"
    else
        fail "G44: mark-step-handler with pre_final_report_gate -> no unknown-step warning (got: $out)"
    fi
}

# ─── workflow_init downstream reset test (G45) ───────────────────────────────

run_g45() {
    require_source "$MARK_STEP_HANDLER" "G45: workflow_init_complete resets downstream steps" || return
    local out
    out=$(run_with_timeout 5 node -e "
const os = require('os');
const path = require('path');
const fs = require('fs');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'g45-wf-'));
process.env.CLAUDE_WORKFLOW_DIR = tmpDir;

const { VALID_STEPS, writeState, readState } = require('$_AGENTS_DIR_NODE/hooks/lib/workflow-state');
const h = require('$MARK_STEP_HANDLER_NODE');

// Seed stale state: all steps complete (prior workflow contamination)
const staleState = { version: 1, session_id: 'g45-sid', created_at: new Date().toISOString(), steps: {}, closes_issues: [999] };
for (const s of VALID_STEPS) staleState.steps[s] = { status: 'complete', updated_at: new Date().toISOString() };
writeState('g45-sid', staleState);

// Fire workflow_init_complete sentinel
const messages = [];
const ctx = {
  cmd: 'echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\"',
  sessionId: 'g45-sid',
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { throw new Error('signalFatal: ' + m); },
};
h.handle(ctx);

// Read back state and verify downstream steps are all pending
const after = readState('g45-sid');
const downstream = VALID_STEPS.filter(s => s !== 'workflow_init');
const allPending = downstream.every(s => (after.steps[s] || {}).status === 'pending');
const wfInitComplete = (after.steps['workflow_init'] || {}).status === 'complete';
process.stdout.write(allPending && wfInitComplete ? 'pass' : 'fail:' + JSON.stringify(Object.fromEntries(VALID_STEPS.map(s => [s, (after.steps[s] || {}).status]))));
" 2>/dev/null)
    if [ "$out" = "pass" ]; then
        pass "G45: workflow_init_complete resets downstream steps to pending"
    else
        fail "G45: workflow_init_complete resets downstream steps to pending (got: $out)"
    fi
}

# ─── Runner ──────────────────────────────────────────────────────────────────

run_g34
run_g35
run_g36
run_g37
run_g38
run_g39
run_g40
run_g41
run_g42
run_g43
run_g44
run_g45

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

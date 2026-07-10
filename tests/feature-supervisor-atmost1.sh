#!/usr/bin/env bash
# tests/feature-supervisor-atmost1.sh
# Tests: hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-guard/collect-audit-triggers.js
# Tags: supervisor, em-supervisor, at-most-1, dedup, audit-verdict, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - Real session where multiple hooks race to arm alert simultaneously
# - audit_verdict durability across real Claude Code Stop cycles
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# SKIPPED: Repeated pre-merge audit attempt after audit_verdict=BLOCK (C9)
# Because: requires workflow-gate.js checkSupervisorPreMerge to exist (not yet implemented);
#   once implemented, the T5 dedup test covers the repeat-arm case; BLOCK verdict
#   durability is covered by T8c
# L3 gap: end-to-end: merge attempted → BLOCK verdict → merge re-attempted → still blocked

# T8: at-most-1 invariants:
# (a) alert_armed_at already set → appendFinding does NOT duplicate/rewrite alert_armed_at
# (b) audit_phase="done" + AUDIT_SEVERITY_THRESHOLD="warning" → collect-audit-triggers does NOT re-arm
# (c) Stop clears audit_phase but keeps audit_verdict (audit_verdict durability)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
COLLECT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-guard/collect-audit-triggers.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr8'; }

if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" ]; then
    skip "T8: supervisor-state-writer.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- T8a: alert_armed_at already set → appendFinding does NOT change alert_armed_at ---
run_t8a() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t8a-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');

// Seed state with alert_armed_at already set
const st = s.createEmptyState('$sid');
const armed_at_before = '2026-01-01T00:00:00.000Z';
st.alert.alert_armed_at = armed_at_before;
st.alert.alert_phase = 'pending';
st.alert.cumulative_severity = 'warning';
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));

// appendFinding with a new finding
const ok = w.appendFinding('$sid', {
    categories: ['workflow'],
    severity: 'warning',
    detail: 'second finding',
    reporter: 'test'
});

const st2 = w.readState('$sid');
const armed_at_after = st2 && st2.alert && st2.alert.alert_armed_at;

// at-most-1: alert_armed_at must remain unchanged
if (armed_at_after !== armed_at_before) {
    console.log('CHANGED:' + armed_at_after);
} else {
    console.log('UNCHANGED');
}
" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ "$out" = "UNCHANGED" ]; then
        pass "T8a: alert_armed_at NOT changed by appendFinding when already set (at-most-1)"
    else
        fail "T8a: alert_armed_at was changed by appendFinding — at-most-1 violated: $out"
    fi
}

# --- T8b: audit_phase="done" → collect-audit-triggers must NOT re-arm ---
run_t8b() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js" ]; then
        skip "T8b: collect-audit-triggers.js not present"
        return
    fi

    local tmp sid out
    tmp=$(make_tmp)
    sid="t8b-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node -e "
const { collectAuditCandidates } = require('$COLLECT_NODE');
const s = require('$SCHEMA_NODE');

// State with audit_phase=done and cumSev=warning
// After #1256, AUDIT_SEVERITY_THRESHOLD='warning', so warning would normally trigger
// But audit_phase=done must prevent re-arm (terminal state)
const st = s.createEmptyState('t8b-inner');
st.alert.cumulative_severity = 'warning';
st.audit.audit_phase = 'done';
st.audit.audit_verdict = 'CONTINUE';

// Empty transcript (no CONFIRM sentinel)
const result = collectAuditCandidates([], st);
process.stdout.write(JSON.stringify(result));
" 2>/dev/null)

    rm -rf "$tmp"

    local should_arm
    should_arm=$(echo "$out" | node -e "
const r = JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String(r.shouldArm));
" 2>/dev/null)

    if [ "$should_arm" = "true" ]; then
        fail "T8b: collect-audit-triggers must NOT re-arm when audit_phase=done (terminal state)"
        return
    fi
    pass "T8b: audit_phase=done → collect-audit-triggers returns shouldArm=false (no re-arm)"
}

# --- T8c: audit_verdict durability — clearing audit_phase via writeAuditState keeps audit_verdict ---
run_t8c() {
    local tmp sid out
    tmp=$(make_tmp)
    sid="t8c-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');

// Seed state with audit_phase=done, audit_verdict=BLOCK
const st = s.createEmptyState('$sid');
st.audit.audit_phase = 'done';
st.audit.audit_verdict = 'BLOCK';
st.audit.audit_last_run_at = new Date().toISOString();
st.audit.audit_cause = 'stage-boundary:CONFIRM_DETAIL';
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));

// Simulate Stop hook clearing audit_phase (what supervisor-guard.js Phase B does)
w.writeAuditState('$sid', { audit_phase: null });

const st2 = w.readState('$sid');
const verdict = st2 && st2.audit && st2.audit.audit_verdict;
const phase = st2 && st2.audit && st2.audit.audit_phase;
process.stdout.write(JSON.stringify({ verdict, phase }));
" 2>/dev/null)

    rm -rf "$tmp"

    local verdict phase
    verdict=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.verdict))" 2>/dev/null)
    phase=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.phase))" 2>/dev/null)

    if [ "$verdict" != "BLOCK" ]; then
        fail "T8c: audit_verdict must persist (BLOCK) after audit_phase cleared, got '$verdict'"
        return
    fi
    if [ "$phase" != "null" ]; then
        fail "T8c: audit_phase must be null after clear, got '$phase'"
        return
    fi
    pass "T8c: audit_verdict=BLOCK persists after audit_phase cleared (verdict durability)"
}

# --- T8d: warning cumSev + AUDIT_SEVERITY_THRESHOLD change → collect-audit-triggers fires at Stop ---
# After Step 5, AUDIT_SEVERITY_THRESHOLD="warning" means cumSev=warning WOULD trigger at (b).
# But Step 6 restricts trigger (b) to cumSev==="error" only at Stop time.
# This test asserts the Step 6 behavior: warning does NOT arm at Stop via collect-audit-triggers.
run_t8d() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js" ]; then
        skip "T8d: collect-audit-triggers.js not present"
        return
    fi

    local tmp sid out
    tmp=$(make_tmp)
    sid="t8d-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node -e "
const { collectAuditCandidates } = require('$COLLECT_NODE');
const s = require('$SCHEMA_NODE');

// State with cumSev=warning, audit not running (null phase)
const st = s.createEmptyState('t8d-inner');
st.alert.cumulative_severity = 'warning';
st.audit.audit_phase = null;

// Empty transcript (no CONFIRM sentinel) — tests trigger (b) only
const result = collectAuditCandidates([], st);
process.stdout.write(JSON.stringify(result));
" 2>/dev/null)

    rm -rf "$tmp"

    local should_arm cause
    should_arm=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.shouldArm))" 2>/dev/null)
    cause=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.cause))" 2>/dev/null)

    # After Step 6: warning must NOT arm at Stop via trigger (b) — only error does
    if [ "$should_arm" = "true" ]; then
        fail "T8d: collect-audit-triggers must NOT arm for cumSev=warning at Stop (Step 6 suppression not yet implemented)"
        return
    fi
    pass "T8d: cumSev=warning + null audit_phase → collect-audit-triggers returns shouldArm=false (Step 6 suppression)"
}

# --- T8e: AUDIT_SEVERITY_THRESHOLD must be 'warning' after #1256 implementation ---
# RED-EXPECTED: current value is 'error'; must become 'warning' after /write-code
run_t8e() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" ]; then
        skip "T8e: supervisor-state-schema.js not present"
        return
    fi
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_NODE');
process.exit(s.AUDIT_SEVERITY_THRESHOLD === 'warning' ? 0 : 1);
" 2>/dev/null
    local rc=$?
    if [ $rc -eq 0 ]; then
        pass "T8e: AUDIT_SEVERITY_THRESHOLD === 'warning' (#1256 implemented)"
    else
        fail "T8e [RED-EXPECTED]: AUDIT_SEVERITY_THRESHOLD must be 'warning' (#1256) but is currently '$(node -e "process.stdout.write(require('$SCHEMA_NODE').AUDIT_SEVERITY_THRESHOLD)" 2>/dev/null)'"
    fi
}

run_t8a
run_t8b
run_t8c
run_t8d
run_t8e

# --- Additional-1: collect-audit-triggers fires on WORKFLOW_CONFIRM_INTENT sentinel ---
# When a conversation transcript contains <<WORKFLOW_CONFIRM_INTENT: ...>>,
# collectAuditCandidates() should return shouldArm=true with a stage-boundary cause.
# This is trigger (a) in collect-audit-triggers.js.
run_additional1_confirm_sentinel() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js" ]; then
        skip "Additional-1: collect-audit-triggers.js not present"
        return
    fi
    if ! command -v node >/dev/null 2>&1; then
        skip "Additional-1: node not available"
        return
    fi

    local out
    out=$(run_with_timeout 10 node -e "
const { collectAuditCandidates } = require('$COLLECT_NODE');
const s = require('$SCHEMA_NODE');

// Transcript: assistant turn with WORKFLOW_CONFIRM_INTENT sentinel in text content
const transcript = [{
    role: 'assistant',
    content: [{ type: 'text', text: '<<WORKFLOW_CONFIRM_INTENT: reviewing scope>>' }]
}];

// Empty state (no audit running, phase null)
const st = s.createEmptyState('add1-inner');
const result = collectAuditCandidates(transcript, st);
process.stdout.write(JSON.stringify(result));
" 2>/dev/null)

    local should_arm cause
    should_arm=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.shouldArm))" 2>/dev/null)
    cause=$(echo "$out" | node -e "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(r.cause||'null'))" 2>/dev/null)

    if [ "$should_arm" != "true" ]; then
        fail "Additional-1: collectAuditCandidates must return shouldArm=true for WORKFLOW_CONFIRM_INTENT sentinel, got shouldArm=$should_arm"
        return
    fi
    if ! echo "$cause" | grep -q "stage-boundary"; then
        fail "Additional-1: cause must contain 'stage-boundary', got '$cause'"
        return
    fi
    pass "Additional-1: WORKFLOW_CONFIRM_INTENT sentinel → collectAuditCandidates returns shouldArm=true, cause=$cause"
}
run_additional1_confirm_sentinel

# --- C8: CONFIRM_RE handles all three stage sentinels + rejects non-sentinels ---
# collect-audit-triggers.js CONFIRM_RE = /<<WORKFLOW_CONFIRM_(INTENT|OUTLINE|DETAIL):/
# Table-driven: assistant-text | expected shouldArm | expected cause-prefix-substring
# The colon is required by the regex — bare <<WORKFLOW_CONFIRM_INTENT>> must NOT arm.
# eval_confirm <text> → prints "shouldArm|cause"
eval_confirm() {
    local text="$1"
    run_with_timeout 10 node -e "
const { collectAuditCandidates } = require('$COLLECT_NODE');
const s = require('$SCHEMA_NODE');
const transcript = [{ role: 'assistant', content: [{ type: 'text', text: process.argv[1] }] }];
const st = s.createEmptyState('c8-inner');
const r = collectAuditCandidates(transcript, st);
process.stdout.write(String(r.shouldArm) + '|' + String(r.cause || 'null'));
" -- "$text" 2>/dev/null
}

run_c8_confirm_table() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js" ]; then
        skip "C8: collect-audit-triggers.js not present"
        return
    fi
    if ! command -v node >/dev/null 2>&1; then
        skip "C8: node not available"
        return
    fi
    # name | assistant-text | want_arm | want_cause_substr
    while IFS='|' read -r name text want_arm want_cause; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want_arm="${want_arm//[[:space:]]/}"
        want_cause="${want_cause#"${want_cause%%[![:space:]]*}"}"
        want_cause="${want_cause%"${want_cause##*[![:space:]]}"}"
        text="${text#"${text%%[![:space:]]*}"}"
        text="${text%"${text##*[![:space:]]}"}"
        local got got_arm got_cause
        got=$(eval_confirm "$text")
        got_arm="${got%%|*}"
        got_cause="${got#*|}"
        if [ "$got_arm" != "$want_arm" ]; then
            fail "C8/$name: want shouldArm=$want_arm got=$got_arm (cause=$got_cause)"
            continue
        fi
        if [ -n "$want_cause" ]; then
            if ! echo "$got_cause" | grep -q "$want_cause"; then
                fail "C8/$name: cause must contain '$want_cause', got '$got_cause'"
                continue
            fi
        fi
        pass "C8/$name: shouldArm=$got_arm cause=$got_cause"
    done <<'TABLE'
confirm-intent   | <<WORKFLOW_CONFIRM_INTENT: reason>>   | true  | stage-boundary:
confirm-outline  | <<WORKFLOW_CONFIRM_OUTLINE: reason>>  | true  | stage-boundary:
confirm-detail   | <<WORKFLOW_CONFIRM_DETAIL: reason>>   | true  | stage-boundary:
non-sentinel     | confirmation received for the intent | false |
bare-no-reason   | <<WORKFLOW_CONFIRM_INTENT>>           | false |
TABLE
}
run_c8_confirm_table

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

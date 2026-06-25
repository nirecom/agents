#!/bin/bash
# tests/feature-720-supervisor-l3-trigger.sh
# Tests: hooks/lib/supervisor-guard/collect-audit-triggers.js
# Tags: supervisor, em-supervisor, layer3, collect, unit, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   Pure function unit test against synthetic transcript+state inputs.
#   Does not verify behavior under a real transcript read from disk by the
#   live Stop-event handler in a claude -p session.
# RED for issue #720.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SRC="$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js"
SRC_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-guard/collect-audit-triggers.js"

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

# Invoke collectAuditCandidates with transcript+state JSON literals.
# Asserts shouldArm matches expected, and (optionally) cause contains substring.
assert_collect() {
    local label="$1" transcript_json="$2" state_json="$3" expect_arm="$4" cause_sub="$5"
    require_source "$SRC" "$label" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$SRC_NODE');
const transcript = $transcript_json;
const state = $state_json;
const r = m.collectAuditCandidates(transcript, state);
if (typeof r !== 'object' || r === null) { console.error('result not object'); process.exit(2); }
if (r.shouldArm !== $expect_arm) { console.error('shouldArm='+r.shouldArm+' expected $expect_arm'); process.exit(3); }
const cs = '$cause_sub';
if (cs && (typeof r.cause !== 'string' || !r.cause.includes(cs))) { console.error('cause='+r.cause+' missing '+cs); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

base_state='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": {}, "layer3": {} }'

run_t1() {
    local tr='[{ "role": "assistant", "content": "going to <<WORKFLOW_CONFIRM_INTENT: scope>> now" }]'
    assert_collect "T1: CONFIRM_INTENT sentinel → shouldArm=true, stage-boundary cause" "$tr" "$base_state" "true" "stage-boundary"
}

run_t2() {
    local tr='[{ "role": "assistant", "content": "now <<WORKFLOW_CONFIRM_OUTLINE: approach>>" }]'
    assert_collect "T2: CONFIRM_OUTLINE sentinel → shouldArm=true" "$tr" "$base_state" "true" ""
}

run_t3() {
    local tr='[{ "role": "assistant", "content": "<<WORKFLOW_CONFIRM_DETAIL: plan>>" }]'
    assert_collect "T3: CONFIRM_DETAIL sentinel → shouldArm=true" "$tr" "$base_state" "true" ""
}

run_t4() {
    local tr='[{ "role": "assistant", "content": "no confirm sentinel here" }]'
    assert_collect "T4: no CONFIRM sentinel → shouldArm=false" "$tr" "$base_state" "false" ""
}

run_t5() {
    local tr='[]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": { "cumulative_severity": "error" }, "layer3": {} }'
    assert_collect "T5: cumulative_severity=error → shouldArm=true, severity-threshold cause" "$tr" "$st" "true" "severity-threshold"
}

run_t6() {
    local tr='[]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": { "cumulative_severity": "warning" }, "layer3": {} }'
    assert_collect "T6: cumulative_severity=warning → shouldArm=false" "$tr" "$st" "false" ""
}

run_t7() {
    local tr='[]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": { "cumulative_severity": null }, "layer3": {} }'
    assert_collect "T7: cumulative_severity=null → shouldArm=false" "$tr" "$st" "false" ""
}

run_t8() {
    local tr='[{ "role": "assistant", "content": "<<WORKFLOW_CONFIRM_INTENT: x>>" }]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": {}, "audit": { "audit_phase": "pending" } }'
    assert_collect "T8: audit_phase=pending (already armed) → shouldArm=false" "$tr" "$st" "false" ""
}

run_t9() {
    local tr='[{ "role": "assistant", "content": "<<WORKFLOW_CONFIRM_INTENT: x>>" }]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": { "cumulative_severity": "error" }, "audit": { "audit_phase": "frozen" } }'
    assert_collect "T9: audit_phase=frozen → shouldArm=false (no re-trigger)" "$tr" "$st" "false" ""
}

run_t10() {
    local tr='[{ "role": "assistant", "content": "<<WORKFLOW_CONFIRM_INTENT: x>>" }]'
    local st='{ "version": "1", "session_id": "t", "layer1": { "findings": [] }, "alert": { "cumulative_severity": "error" }, "audit": { "audit_phase": "in_progress" } }'
    assert_collect "T10: audit_phase=in_progress → shouldArm=false (no double-arm while running)" "$tr" "$st" "false" ""
}

run_t1; run_t2; run_t3; run_t4; run_t5; run_t6; run_t7; run_t8; run_t9; run_t10

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

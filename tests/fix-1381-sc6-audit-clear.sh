#!/usr/bin/env bash
# tests/fix-1381-sc6-audit-clear.sh
# Tests: bin/supervisor-write-audit, hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, sc6, audit-clear, clear-audit-phase, dual-store, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - session-close SC-6 invoking supervisor-write-audit inside a real claude -p Stop-hook session
# - CLAUDE_SESSION_ID / WORKFLOW_SESSION_ID env propagation across a real hook subprocess boundary
#   (Anthropic bug #27987) — here both IDs are passed explicitly via flags
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# #1381: session-close SC-6 must clear BOTH audit_armed_at AND audit_phase so a stale
# "pending" audit does not survive into the next cycle. Requires a new --clear-audit-phase
# flag on bin/supervisor-write-audit.
# T1 (RED until #1381): --clear-audit-phase clears audit_phase to null (single store).
# T2 (RED until #1381): --clear-audit-phase mirrors to a second store (dual-store).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-audit"
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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'fix1381'; }

if ! command -v node >/dev/null 2>&1; then
    skip "T1/T2-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Seed a supervisor state with audit_phase=pending + audit_armed_at set (non-null).
seed_audit_pending() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.audit.audit_phase = 'pending';
st.audit.audit_armed_at = new Date().toISOString();
st.audit.audit_cause = 'stage-boundary:CONFIRM_DETAIL';
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Read audit_phase and audit_armed_at as a "phase|armed" string ("null"|"null" when both null).
read_audit() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const au = (st && st.audit) || {};
const ph = au.audit_phase == null ? 'null' : String(au.audit_phase);
const armed = au.audit_armed_at == null ? 'null' : 'set';
process.stdout.write(ph + '|' + armed);
" 2>/dev/null
}

# --- T1: single store, --clear-audit-armed-at + --clear-audit-phase → both null ---
run_t1_clear_phase_single() {
    local tmp sid out rc audit
    tmp=$(make_tmp)
    sid="fix1381-t1-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    seed_audit_pending "$tmp_node" "$sid"

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$CLI" \
        --session-id "$sid" --clear-audit-armed-at --clear-audit-phase 2>&1)
    rc=$?

    audit=$(read_audit "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "T1 [RED-EXPECTED until #1381]: --clear-audit-phase unknown flag (rc=$rc): $(printf '%q' "${out:0:120}")"
        return
    fi
    if [ "$audit" = "null|null" ]; then
        pass "T1: --clear-audit-phase + --clear-audit-armed-at → audit_phase=null AND audit_armed_at=null"
    else
        fail "T1: expected audit_phase=null AND audit_armed_at=null (got '$audit')"
    fi
}

# --- T2: dual-store, --mirror-session-id → both stores cleared ---
run_t2_clear_phase_dual() {
    local tmp sid wsid out rc audit_cc audit_ws
    tmp=$(make_tmp)
    sid="fix1381-t2-cc-$$"
    wsid="fix1381-t2-ws-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    seed_audit_pending "$tmp_node" "$sid"
    seed_audit_pending "$tmp_node" "$wsid"

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$CLI" \
        --session-id "$sid" --mirror-session-id "$wsid" \
        --clear-audit-armed-at --clear-audit-phase 2>&1)
    rc=$?

    audit_cc=$(read_audit "$tmp_node" "$sid")
    audit_ws=$(read_audit "$tmp_node" "$wsid")
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "T2 [RED-EXPECTED until #1381]: --clear-audit-phase unknown flag (rc=$rc): $(printf '%q' "${out:0:120}")"
        return
    fi
    if [ "$audit_cc" = "null|null" ] && [ "$audit_ws" = "null|null" ]; then
        pass "T2: dual-store --clear-audit-phase → BOTH stores audit_phase=null AND audit_armed_at=null"
    else
        fail "T2: expected both stores cleared (cc='$audit_cc' ws='$audit_ws')"
    fi
}

run_t1_clear_phase_single
run_t2_clear_phase_dual

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

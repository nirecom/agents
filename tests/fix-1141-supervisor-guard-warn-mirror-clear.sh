#!/usr/bin/env bash
# Tests: hooks/supervisor-guard.js (Phase B WARN path alert_armed_at mirror-clear)
# Tags: supervisor, em-supervisor, layer2, hook, stop, dual-store, fix-1141, scope:issue-specific
# RED for issue #1141.
#
# Validates that supervisor-guard.js Phase B WARN path clears alert_armed_at on both
# the effective-state store and its mirror store when audit_verdict=WARN is surfaced.
#
# The fix adds, inside `if (arbitration.decision === "warn")` after setting
# pendingAuditWarnContext:
#   writeAlertState(effectiveSupervisorStateSessionId, { alert_armed_at: null })
#   + mirror clear to the other identity's store.
#
# Setup for effective-state-sid = wsid:
#   - CC UUID state: exists but unarmed (alert_armed_at=null)
#   - wsid state: armed (alert_armed_at set), audit_phase=done, audit_verdict=WARN
#   → dual-store fallback selects wsid as effectiveSupervisorStateSessionId
#   → Phase B reads audit_phase=done, audit_verdict=WARN → arbitration.decision="warn"
#   → fix clears alert_armed_at on wsid (effective) and mirrors clear to CC UUID
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if supervisor-guard.js is
#   not wired, the Phase B WARN path is entirely unobservable.
# - real Claude Code transcript format differences and WORKFLOW_SESSION_ID env propagation
# Closest-to-action mitigation: hook-registration category in
#   bin/check-verification-gate.sh fires at WORKFLOW_USER_VERIFIED preflight.

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

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# Read alert_armed_at from a state file via node.
read_alert_armed_at() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.alert) { process.stdout.write('MISSING'); process.exit(0); }
process.stdout.write(st.alert.alert_armed_at === null ? 'null' : String(st.alert.alert_armed_at));
" 2>/dev/null
}

# L2: Phase B WARN path — guard exits 0, effective store (wsid) alert_armed_at is null,
# mirror store (CC UUID) alert_armed_at is also null after the fix.
#
# Setup:
#   CC UUID (sessionId) state: exists, alert_armed_at=null (unarmed)
#   wsid state: alert_armed_at=<timestamp> (armed), audit_phase=done, audit_verdict=WARN
#   → effectiveSupervisorStateSessionId = wsid (dual-store fallback picks wsid because
#     CC UUID is unarmed but wsid is armed)
#   Guard reads wsid state: audit_phase=done → Phase B fires → arbitration.decision=warn
#   → pendingAuditWarnContext set → guard emits additionalContext → exit 0
#   → fix: writeAlertState(wsid, {alert_armed_at:null}) + mirror clear to CC UUID
run_l2() {
    require_source "$HOOK" "L2: Phase B WARN path clears alert_armed_at on effective store (wsid) and mirror (CC UUID)" || return
    require_source "$WRITER_NODE" "L2: supervisor-state-writer.js exists" || return

    local tmp cc_uuid wsid out rc wsid_armed_after cc_armed_after
    tmp="$(mktemp -d)"
    cc_uuid="ccuuid-warn-l2"
    wsid="wsid-warn-l2"

    # Seed CC UUID state: exists but unarmed
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$cc_uuid');
st.alert.alert_armed_at = null;
st.alert.alert_phase = null;
fs.writeFileSync(w.getStatePath('$cc_uuid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Seed wsid state: armed + audit_phase=done, audit_verdict=WARN
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$wsid');
st.alert.alert_armed_at = new Date().toISOString();
st.alert.alert_phase = null;
st.audit.audit_phase = 'done';
st.audit.audit_verdict = 'WARN';
st.audit.audit_cause = 'test audit warn';
fs.writeFileSync(w.getStatePath('$wsid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Run guard: session_id=CC UUID, WORKFLOW_SESSION_ID=wsid (propagated via env)
    # The guard resolves workflowSessionId from WORKFLOW_SESSION_ID env var (line 261-262).
    # session_hash is not used for state resolution — omit it (or pass CC UUID).
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$cc_uuid\",\"transcript_path\":\"\",\"session_hash\":\"$cc_uuid\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_SESSION_ID="$wsid" \
          run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?

    wsid_armed_after=$(read_alert_armed_at "$tmp" "$wsid")
    cc_armed_after=$(read_alert_armed_at "$tmp" "$cc_uuid")

    rm -rf "$tmp"

    # Guard must exit 0 (WARN surfaces as additionalContext, not block)
    if [ "$rc" -ne 0 ]; then
        fail "L2: Phase B WARN path — guard exited $rc (expected 0); out=$out"
        return
    fi

    # Guard output must contain additionalContext (WARN path emits additionalContext)
    if ! echo "$out" | grep -q "additionalContext"; then
        fail "L2: Phase B WARN path — guard output missing additionalContext; rc=$rc out=$out"
        return
    fi

    # After the fix: wsid store alert_armed_at must be null
    if [ "$wsid_armed_after" != "null" ]; then
        fail "L2: Phase B WARN path — wsid alert_armed_at not cleared (got: $wsid_armed_after); fix #1141 not yet applied"
        return
    fi

    # After the fix: CC UUID mirror store alert_armed_at must also be null (mirror clear)
    if [ "$cc_armed_after" != "null" ]; then
        fail "L2: Phase B WARN path — CC UUID alert_armed_at not mirror-cleared (got: $cc_armed_after); fix #1141 not yet applied"
        return
    fi

    pass "L2: Phase B WARN path clears alert_armed_at on effective store (wsid) and mirror (CC UUID)"
}

# S1: hooks/supervisor-guard.js WARN branch contains alert_armed_at clear code.
# The fix adds a writeAlertState call with { alert_armed_at: null } inside
# `if (arbitration.decision === "warn")` — specifically a writeAlertState call
# that is not just a read/condition but an actual write call with the null clear.
run_s1() {
    require_source "$HOOK" "S1: supervisor-guard.js WARN branch contains writeAlertState alert_armed_at clear" || return
    # The fix adds writeAlertState(effectiveSupervisorStateSessionId, { alert_armed_at: null })
    # inside the warn decision block. Check for writeAlertState being called with alert_armed_at:null.
    # Use a pattern that can't match existing read/condition code.
    if grep -q 'writeAlertState.*alert_armed_at.*null\|alert_armed_at.*null.*writeAlertState' "$HOOK"; then
        pass "S1: supervisor-guard.js WARN branch contains writeAlertState alert_armed_at clear"
    else
        fail "S1: supervisor-guard.js WARN branch missing writeAlertState alert_armed_at clear (fix #1141 not yet applied)"
    fi
}

run_l2
run_s1

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

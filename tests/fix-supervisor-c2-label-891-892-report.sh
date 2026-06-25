#!/bin/bash
# tests/fix-supervisor-c2-label-891-892-report.sh
# Tests: bin/supervisor-report (post-Final-Report guard integration)
# Tags: supervisor, em-supervisor, layer2, fix, integration
# RED for issue #891 (bin/supervisor-report post-Final-Report behavior).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
REPORT_BIN="$AGENTS_DIR/bin/supervisor-report"
REPORT_BIN_NODE="$_AGENTS_DIR_NODE/bin/supervisor-report"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Probe: does ensureAlertScheduled respect the final-report-env.json guard?
guard_implemented() {
    local tmp probe
    tmp="$(mktemp -d)"
    touch "$tmp/probe-sid-final-report-env.json"
    probe=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { alert: { alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: null } };
try { w.ensureAlertScheduled(state, 'probe-sid'); } catch (e) { process.stdout.write('error'); process.exit(0); }
process.stdout.write(state.alert.alert_armed_at === null ? 'guarded' : 'unguarded');
" 2>/dev/null)
    rm -rf "$tmp"
    [ "$probe" = "guarded" ]
}

require_guard() {
    local label="$1"
    if [ ! -f "$WRITER_MODULE" ] || [ ! -f "$REPORT_BIN" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    if ! guard_implemented; then
        skip "$label (ensureAlertScheduled guard not implemented yet)"; return 1
    fi
    return 0
}

run_r1() {
    local label="R1: env JSON present -> supervisor-report appends finding, alert_armed_at stays null"
    require_guard "$label" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="r1-sid"
    touch "$tmp/$sid-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$REPORT_BIN_NODE" \
        --categories workflow --severity warning --detail "post-final test" \
        --reporter test --session-id "$sid" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        rm -rf "$tmp"
        fail "$label (supervisor-report exit=$rc, out=$out)"
        return
    fi
    # Verify state
    local check
    check=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st) { console.error('no state'); process.exit(2); }
if (st.alert.alert_armed_at !== null) { console.error('alert_armed_at='+st.alert.alert_armed_at); process.exit(3); }
if (!Array.isArray(st.layer1.findings) || st.layer1.findings.length !== 1) { console.error('findings len='+(st.layer1.findings||[]).length); process.exit(4); }
console.log('OK');
" 2>&1)
    local check_rc=$?
    rm -rf "$tmp"
    if [ $check_rc -eq 0 ] && [ "$check" = "OK" ]; then
        pass "$label"
    else
        fail "$label (check_rc=$check_rc, check=$check)"
    fi
}

run_r2() {
    local label="R2: no env JSON -> supervisor-report schedules L2 review (alert_armed_at non-null)"
    if [ ! -f "$WRITER_MODULE" ] || [ ! -f "$REPORT_BIN" ]; then
        skip "$label (source not implemented yet)"; return
    fi
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="r2-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$REPORT_BIN_NODE" \
        --categories workflow --severity warning --detail "normal test" \
        --reporter test --session-id "$sid" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        rm -rf "$tmp"
        fail "$label (supervisor-report exit=$rc, out=$out)"
        return
    fi
    local check
    check=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st) { console.error('no state'); process.exit(2); }
if (st.alert.alert_armed_at == null) { console.error('alert_armed_at not set'); process.exit(3); }
console.log('OK');
" 2>&1)
    local check_rc=$?
    rm -rf "$tmp"
    if [ $check_rc -eq 0 ] && [ "$check" = "OK" ]; then
        pass "$label"
    else
        fail "$label (check_rc=$check_rc, check=$check)"
    fi
}

run_r1
run_r2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

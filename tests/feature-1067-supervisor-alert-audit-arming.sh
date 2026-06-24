#!/bin/bash
# tests/feature-1067-supervisor-alert-audit-arming.sh
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, alert, arming, scope:issue-specific
# Tests for issue #1067 — ensureAlertScheduled arming threshold contract.
# Cases: warning finding -> arms; notice finding -> does NOT arm; null -> arms.
#
# RED: All cases FAIL/SKIP until source changes land (ensureAlertScheduled not renamed,
# arming threshold logic not added).
#
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event integration — tests call writer directly
# - arming effect propagating through the full hook dispatch chain
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

# Check that ensureAlertScheduled is exported (renamed from ensureLayer2Scheduled)
require_ensure_alert_scheduled() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
process.stdout.write(typeof w.ensureAlertScheduled === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (ensureAlertScheduled not implemented yet)"; return 1
    fi
    return 0
}

# ARM1: ensureAlertScheduled with finding.severity="warning" -> alert_armed_at set
run_arm1() {
    require_source "$WRITER_MODULE" "ARM1: ensureAlertScheduled with warning finding -> arms" || return
    require_ensure_alert_scheduled "ARM1: ensureAlertScheduled with warning finding -> arms" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_MODULE_NODE');
const s = require('$SCHEMA_MODULE_NODE');
const fs = require('fs');
const st = s.createEmptyState('arm1-sid');
const finding = { categories: ['workflow'], severity: 'warning', detail: 'test block', reporter: 'enforce-worktree' };
w.ensureAlertScheduled(st, 'arm1-sid', finding);
const armed = st.alert && st.alert.alert_armed_at;
if (!armed) { console.error('alert_armed_at not set'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "ARM1: ensureAlertScheduled with warning finding -> arms"
    else
        fail "ARM1: ensureAlertScheduled with warning finding -> arms (rc=$rc, out=$out)"
    fi
}

# ARM2: ensureAlertScheduled with finding.severity="notice" -> does NOT arm
run_arm2() {
    require_source "$WRITER_MODULE" "ARM2: ensureAlertScheduled with notice finding -> does NOT arm" || return
    require_ensure_alert_scheduled "ARM2: ensureAlertScheduled with notice finding -> does NOT arm" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_MODULE_NODE');
const s = require('$SCHEMA_MODULE_NODE');
const fs = require('fs');
const st = s.createEmptyState('arm2-sid');
const finding = { categories: ['other'], severity: 'notice', detail: 'low severity obs', reporter: 'session-close' };
w.ensureAlertScheduled(st, 'arm2-sid', finding);
const armed = st.alert && st.alert.alert_armed_at;
if (armed !== null && armed !== undefined) { console.error('alert_armed_at set to: '+armed); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "ARM2: ensureAlertScheduled with notice finding -> does NOT arm"
    else
        fail "ARM2: ensureAlertScheduled with notice finding -> does NOT arm (rc=$rc, out=$out)"
    fi
}

# ARM3: ensureAlertScheduled with finding=null -> arms (backward-compat)
run_arm3() {
    require_source "$WRITER_MODULE" "ARM3: ensureAlertScheduled with null finding -> arms (backward-compat)" || return
    require_ensure_alert_scheduled "ARM3: ensureAlertScheduled with null finding -> arms (backward-compat)" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_MODULE_NODE');
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('arm3-sid');
w.ensureAlertScheduled(st, 'arm3-sid', null);
const armed = st.alert && st.alert.alert_armed_at;
if (!armed) { console.error('alert_armed_at not set for null finding'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "ARM3: ensureAlertScheduled with null finding -> arms (backward-compat)"
    else
        fail "ARM3: ensureAlertScheduled with null finding -> arms (backward-compat) (rc=$rc, out=$out)"
    fi
}

# ARM4: ensureAlertScheduled with finding.severity="error" -> arms
run_arm4() {
    require_source "$WRITER_MODULE" "ARM4: ensureAlertScheduled with error finding -> arms" || return
    require_ensure_alert_scheduled "ARM4: ensureAlertScheduled with error finding -> arms" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_MODULE_NODE');
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('arm4-sid');
const finding = { categories: ['workflow'], severity: 'error', detail: 'hook blocked', reporter: 'enforce-worktree' };
w.ensureAlertScheduled(st, 'arm4-sid', finding);
const armed = st.alert && st.alert.alert_armed_at;
if (!armed) { console.error('alert_armed_at not set for error finding'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "ARM4: ensureAlertScheduled with error finding -> arms"
    else
        fail "ARM4: ensureAlertScheduled with error finding -> arms (rc=$rc, out=$out)"
    fi
}

run_arm1
run_arm2
run_arm3
run_arm4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

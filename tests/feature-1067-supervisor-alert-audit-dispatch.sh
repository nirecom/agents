#!/bin/bash
# tests/feature-1067-supervisor-alert-audit-dispatch.sh
# Tests: hooks/supervisor-guard.js, hooks/lib/final-report-schema.js, bin/supervisor-write-alert, bin/supervisor-write-audit, bin/supervisor-write-audit-verdict
# Tags: supervisor, em-supervisor, dispatch, c3, alert, audit, final-report, scope:issue-specific
# Tests for issue #1067 — guard audit dispatch references supervisor-audit.md;
# final-report-schema renders alert/audit placeholders;
# CLI binaries accept new flags.
#
# RED: Fails until source changes land.
#
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event integration for C3 detection
# - live agent invocation via supervisor-audit.md
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
FINAL_REPORT_SCHEMA="$AGENTS_DIR/hooks/lib/final-report-schema.js"
FINAL_REPORT_SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/final-report-schema.js"
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

# DI1: guard source references agents/supervisor-audit.md (not supervisor-layer3.md)
run_di1() {
    local label="DI1: guard dispatch references agents/supervisor-audit.md"
    require_source "$HOOK" "$label" || return
    if grep -q 'supervisor-audit.md' "$HOOK"; then
        pass "$label"
    else
        fail "$label (agents/supervisor-audit.md not found in hook source)"
    fi
}

# DI2: guard source does NOT reference supervisor-layer3.md
run_di2() {
    local label="DI2: guard dispatch does NOT reference supervisor-layer3.md"
    require_source "$HOOK" "$label" || return
    if grep -q 'supervisor-layer3.md' "$HOOK"; then
        fail "$label (supervisor-layer3.md still referenced in hook)"
    else
        pass "$label"
    fi
}

# DI3: final-report-schema renderSkeleton contains <SUPERVISOR_ALERT_SUMMARY>
run_di3() {
    local label="DI3: renderSkeleton contains <SUPERVISOR_ALERT_SUMMARY>"
    require_source "$FINAL_REPORT_SCHEMA" "$label" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$FINAL_REPORT_SCHEMA_NODE');
const skel = s.renderSkeleton('test-sid-di3');
if (skel.indexOf('<SUPERVISOR_ALERT_SUMMARY>') === -1) { console.error('SUPERVISOR_ALERT_SUMMARY not found'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# DI4: final-report-schema renderSkeleton contains <SUPERVISOR_AUDIT_SUMMARY>
run_di4() {
    local label="DI4: renderSkeleton contains <SUPERVISOR_AUDIT_SUMMARY>"
    require_source "$FINAL_REPORT_SCHEMA" "$label" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$FINAL_REPORT_SCHEMA_NODE');
const skel = s.renderSkeleton('test-sid-di4');
if (skel.indexOf('<SUPERVISOR_AUDIT_SUMMARY>') === -1) { console.error('SUPERVISOR_AUDIT_SUMMARY not found'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# DI5: bin/supervisor-write-alert exists
run_di5() {
    local label="DI5: bin/supervisor-write-alert exists"
    if [ -f "$AGENTS_DIR/bin/supervisor-write-alert" ]; then
        pass "$label"
    else
        fail "$label (bin/supervisor-write-alert not found)"
    fi
}

# DI6: bin/supervisor-write-audit exists
run_di6() {
    local label="DI6: bin/supervisor-write-audit exists"
    if [ -f "$AGENTS_DIR/bin/supervisor-write-audit" ]; then
        pass "$label"
    else
        fail "$label (bin/supervisor-write-audit not found)"
    fi
}

# DI7: bin/supervisor-write-audit-verdict exists
run_di7() {
    local label="DI7: bin/supervisor-write-audit-verdict exists"
    if [ -f "$AGENTS_DIR/bin/supervisor-write-audit-verdict" ]; then
        pass "$label"
    else
        fail "$label (bin/supervisor-write-audit-verdict not found)"
    fi
}

# DI8: bin/supervisor-write-alert accepts --set-alert-phase flag
run_di8() {
    local label="DI8: bin/supervisor-write-alert accepts --set-alert-phase flag"
    if [ ! -f "$AGENTS_DIR/bin/supervisor-write-alert" ]; then
        skip "$label (bin/supervisor-write-alert not found)"; return
    fi
    local tmp out rc
    tmp="$(mktemp -d)"
    # seed a state file first
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('di8-sid');
fs.writeFileSync(w.getStatePath('di8-sid'), JSON.stringify(st));
" >/dev/null 2>&1
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$AGENTS_DIR/bin/supervisor-write-alert" \
        --session-id "di8-sid" --set-alert-phase "pending" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# DI9: bin/supervisor-write-audit accepts --set-audit-phase flag
run_di9() {
    local label="DI9: bin/supervisor-write-audit accepts --set-audit-phase flag"
    if [ ! -f "$AGENTS_DIR/bin/supervisor-write-audit" ]; then
        skip "$label (bin/supervisor-write-audit not found)"; return
    fi
    local tmp out rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('di9-sid');
fs.writeFileSync(w.getStatePath('di9-sid'), JSON.stringify(st));
" >/dev/null 2>&1
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$AGENTS_DIR/bin/supervisor-write-audit" \
        --session-id "di9-sid" --set-audit-phase "pending" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

run_di1
run_di2
run_di3
run_di4
run_di5
run_di6
run_di7
run_di8
run_di9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

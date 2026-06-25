#!/bin/bash
# tests/feature-997-late-finding-arm-integration.sh
# Tests: hooks/lib/supervisor-state-writer.js, bin/supervisor-write-alert
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #997 — late finding arming via eligibility flag.
# End-to-end state simulation against a real tmpdir-backed WORKFLOW_PLANS_DIR.
#
# # L3 gap
# L2 exercises the writer + CLI with real file I/O. L3 (live Stop event under
# `claude -p`) is required to verify the actual late-firing user path.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_SRC="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
CLI="$AGENTS_DIR/bin/supervisor-write-alert"

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

append_finding() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const ok = w.appendFinding('$sid', { categories:['code'], severity:'warning', detail:'late-' + Date.now() + Math.random(), reporter:'rep' });
if (!ok) { console.error('append failed'); process.exit(2); }
" >/dev/null 2>&1
}

read_armed_at() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st) { process.exit(2); }
const v = st.alert.alert_armed_at;
if (v === null) console.log('NULL'); else console.log(v);
" 2>/dev/null
}

# --- L1: baseline — no anchor, appendFinding arms ---------------------------
run_l1() {
    require_source "$WRITER_SRC" "L1: baseline appendFinding arms" || return
    local tmp armed
    tmp="$(mktemp -d)"
    append_finding "$tmp" "l1-sid"
    armed="$(read_armed_at "$tmp" "l1-sid")"
    rm -rf "$tmp"
    if [ "$armed" != "NULL" ] && [ -n "$armed" ]; then
        pass "L1 (baseline): no anchor, appendFinding sets alert_armed_at"
    else
        fail "L1: baseline arm failed (armed=$armed)"
    fi
}

# --- L2: anchor blocks normal arm -------------------------------------------
run_l2() {
    require_source "$WRITER_SRC" "L2: anchor blocks arm" || return
    local tmp armed
    tmp="$(mktemp -d)"
    : > "$tmp/l2-sid-final-report-env.json"
    append_finding "$tmp" "l2-sid"
    armed="$(read_armed_at "$tmp" "l2-sid")"
    rm -rf "$tmp"
    if [ "$armed" = "NULL" ]; then
        pass "L2 (anchor blocks): final-report-env.json present -> arm skipped"
    else
        fail "L2: anchor did not block arm (armed=$armed)"
    fi
}

# --- L3: eligibility re-enables arm with anchor still present ---------------
run_l3() {
    require_source "$WRITER_SRC" "L3: eligibility enables late arm with anchor present" || return
    require_source "$CLI" "L3: CLI required" || return
    local tmp armed_before armed_after
    tmp="$(mktemp -d)"
    : > "$tmp/l3-sid-final-report-env.json"
    append_finding "$tmp" "l3-sid"
    armed_before="$(read_armed_at "$tmp" "l3-sid")"
    # Promote eligibility via CLI
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id l3-sid --set-alert-eligible-phase post_final_report_window >/dev/null 2>&1
    append_finding "$tmp" "l3-sid"
    armed_after="$(read_armed_at "$tmp" "l3-sid")"
    rm -rf "$tmp"
    if [ "$armed_before" = "NULL" ] && [ "$armed_after" != "NULL" ] && [ -n "$armed_after" ]; then
        pass "L3 (eligibility enables): anchor + eligibility -> late arm fires"
    else
        fail "L3: late arm (before=$armed_before, after=$armed_after)"
    fi
}

# --- L4: done overrides eligibility -----------------------------------------
run_l4() {
    require_source "$WRITER_SRC" "L4: done overrides eligibility" || return
    require_source "$CLI" "L4: CLI required" || return
    local tmp armed
    tmp="$(mktemp -d)"
    # No anchor; explicitly mark done with eligibility set
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id l4-sid --set-alert-eligible-phase post_final_report_window >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id l4-sid --set-alert-phase done >/dev/null 2>&1
    append_finding "$tmp" "l4-sid"
    armed="$(read_armed_at "$tmp" "l4-sid")"
    rm -rf "$tmp"
    if [ "$armed" = "NULL" ]; then
        pass "L4 (done overrides): alert_phase=done overrides eligibility -> no arm"
    else
        fail "L4: done did not override eligibility (armed=$armed)"
    fi
}

run_l1
run_l2
run_l3
run_l4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL

#!/bin/bash
# tests/feature-1027-supervisor-write-layer2-flags.sh
# Tests: bin/supervisor-write-layer2, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 — CLI flags --mark-findings-surfaced and
# --set-l2-eligible-phase <value>.
#
# # L3 gap
# CLI exercised at L2 (real process spawn + tmpdir state). L3 would require
# a live Stop-hook firing under `claude -p`; covered by the stop-hook E2E
# suite separately.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-layer2"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

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

# --- C1: --mark-findings-surfaced writes a non-null ISO timestamp -----------
run_c1() {
    require_source "$CLI" "C1: --mark-findings-surfaced writes ISO timestamp" || return
    local tmp rc out
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c1-sid --mark-findings-surfaced >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
        rm -rf "$tmp"
        fail "C1: CLI returned non-zero (rc=$rc) for --mark-findings-surfaced"
        return
    fi
    out="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('c1-sid');
if (!st) { process.exit(2); }
const v = st.layer2.findings_surfaced_at;
if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(v)) { process.exit(3); }
console.log('OK');
" 2>/dev/null)"
    rm -rf "$tmp"
    if [ "$out" = "OK" ]; then
        pass "C1: --mark-findings-surfaced writes ISO timestamp"
    else
        fail "C1: timestamp not written / not ISO (out=$out)"
    fi
}

# --- C2: --set-l2-eligible-phase post_final_report_window persists ----------
run_c2() {
    require_source "$CLI" "C2: --set-l2-eligible-phase post_final_report_window" || return
    local tmp rc out
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c2-sid --set-l2-eligible-phase post_final_report_window >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
        rm -rf "$tmp"
        fail "C2: CLI returned non-zero (rc=$rc)"
        return
    fi
    out="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('c2-sid');
if (!st) { process.exit(2); }
if (st.layer2.l2_eligible_phase !== 'post_final_report_window') { process.exit(3); }
console.log('OK');
" 2>/dev/null)"
    rm -rf "$tmp"
    if [ "$out" = "OK" ]; then
        pass "C2: --set-l2-eligible-phase post_final_report_window persists"
    else
        fail "C2: l2_eligible_phase not persisted (out=$out)"
    fi
}

# --- C3: --set-l2-eligible-phase null clears the field ----------------------
run_c3() {
    require_source "$CLI" "C3: --set-l2-eligible-phase null clears the field" || return
    local tmp rc out
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c3-sid --set-l2-eligible-phase post_final_report_window >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c3-sid --set-l2-eligible-phase null >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
        rm -rf "$tmp"
        fail "C3: second CLI call returned non-zero (rc=$rc)"
        return
    fi
    out="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('c3-sid');
if (!st) { process.exit(2); }
if (st.layer2.l2_eligible_phase !== null) { process.exit(3); }
console.log('OK');
" 2>/dev/null)"
    rm -rf "$tmp"
    if [ "$out" = "OK" ]; then
        pass "C3: --set-l2-eligible-phase null clears the field"
    else
        fail "C3: l2_eligible_phase not cleared (out=$out)"
    fi
}

# --- C4: invalid value -> exit 1 with usage on stderr -----------------------
run_c4() {
    require_source "$CLI" "C4: --set-l2-eligible-phase invalid -> exit 1 + usage" || return
    local tmp rc err
    tmp="$(mktemp -d)"
    err="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c4-sid --set-l2-eligible-phase normal_run 2>&1 >/dev/null)"
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" != "0" ] && echo "$err" | grep -qi "usage\|set-l2-eligible-phase\|invalid\|must be"; then
        pass "C4: invalid --set-l2-eligible-phase value -> exit non-zero + usage/error on stderr"
    else
        fail "C4: expected non-zero exit + usage (rc=$rc, err=$err)"
    fi
}

# --- C5: --mark-findings-surfaced combined with --set-l2-phase done ----------
run_c5() {
    require_source "$CLI" "C5: --mark-findings-surfaced + --set-l2-phase done both succeed" || return
    local tmp rc out
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --session-id c5-sid --mark-findings-surfaced --set-l2-phase done >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
        rm -rf "$tmp"
        fail "C5: combined invocation returned non-zero (rc=$rc)"
        return
    fi
    out="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('c5-sid');
if (!st) { process.exit(2); }
if (typeof st.layer2.findings_surfaced_at !== 'string') { process.exit(3); }
if (st.layer2.l2_phase !== 'done') { process.exit(4); }
console.log('OK');
" 2>/dev/null)"
    rm -rf "$tmp"
    if [ "$out" = "OK" ]; then
        pass "C5: --mark-findings-surfaced + --set-l2-phase done both apply"
    else
        fail "C5: combined effects not applied (out=$out)"
    fi
}

# --- C6: missing --session-id -> exit non-zero with usage on stderr ---------
run_c6() {
    require_source "$CLI" "C6: missing --session-id -> exit non-zero + usage" || return
    local tmp rc err
    tmp="$(mktemp -d)"
    err="$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI" --mark-findings-surfaced 2>&1 >/dev/null)"
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" != "0" ] && echo "$err" | grep -qi "session-id\|usage"; then
        pass "C6: missing --session-id -> exit non-zero + usage/error on stderr"
    else
        fail "C6: expected non-zero exit + usage when --session-id absent (rc=$rc, err=$err)"
    fi
}

run_c1
run_c2
run_c3
run_c4
run_c5
run_c6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL

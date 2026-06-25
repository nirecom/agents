#!/bin/bash
# tests/feature-929-supervisor-write-alert-status.sh
# Tests: bin/supervisor-write-alert (new --finding-status, --confirm-finding-ids, --drop-finding-ids flags)
# Tags: supervisor, em-supervisor, cli, layer2, finding-status
# RED for issue #929.
#
# L3 gap (what this test does NOT catch):
# - real supervisor agent invoking the full flow inside a live Claude Code session
# - Codex API network call succeeding end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-alert"
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

require_flag_supported() {
    local flag="$1" label="$2"
    if [ ! -f "$CLI" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    # Probe usage output for the flag string. If absent, skip.
    local probe
    probe=$(run_with_timeout 5 node "$CLI" --no-such-flag 2>&1 || true)
    if ! echo "$probe" | grep -q -- "$flag"; then
        skip "$label ($flag not implemented yet)"; return 1
    fi
    return 0
}

# Helper: writes a draft finding via CLI; emits sid and tmp via stdout.
seed_finding() {
    local tmp="$1" sid="$2" status="$3" detail="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --finding-categories workflow \
        --finding-severity warning \
        --finding-detail "$detail" \
        --finding-reporter supervisor \
        --finding-status "$status" \
        --session-id "$sid" >/dev/null 2>&1
}

read_finding_field() {
    local tmp="$1" sid="$2" idx="$3" field="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const f = st && st.alert && st.alert.findings && st.alert.findings[$idx];
process.stdout.write(f ? JSON.stringify(f.$field) : 'MISSING');
" 2>/dev/null
}

read_findings_len() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(String((st && st.alert && st.alert.findings && st.alert.findings.length) || 0));
" 2>/dev/null
}

run_wl1() {
    require_flag_supported "--finding-status" "WL1: --finding-status draft stores status:draft" || return
    local tmp sid status
    tmp="$(mktemp -d)"; sid="wl1-sid"
    seed_finding "$tmp" "$sid" "draft" "d1"
    status=$(read_finding_field "$tmp" "$sid" 0 "status")
    rm -rf "$tmp"
    if [ "$status" = '"draft"' ]; then
        pass "WL1: --finding-status draft stores status:draft"
    else
        fail "WL1: status=$status"
    fi
}

run_wl2() {
    require_flag_supported "--finding-status" "WL2: --finding-status confirmed stores status:confirmed" || return
    local tmp sid status
    tmp="$(mktemp -d)"; sid="wl2-sid"
    seed_finding "$tmp" "$sid" "confirmed" "d2"
    status=$(read_finding_field "$tmp" "$sid" 0 "status")
    rm -rf "$tmp"
    if [ "$status" = '"confirmed"' ]; then
        pass "WL2: --finding-status confirmed stores status:confirmed"
    else
        fail "WL2: status=$status"
    fi
}

run_wl3() {
    # Backward compat — omitting --finding-status should still work (default behavior).
    if [ ! -f "$CLI" ]; then skip "WL3: omit --finding-status default (source not implemented)"; return; fi
    local tmp sid rc len
    tmp="$(mktemp -d)"; sid="wl3-sid"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --finding-categories workflow \
        --finding-severity warning \
        --finding-detail "d3" \
        --finding-reporter supervisor \
        --session-id "$sid" >/dev/null 2>&1
    rc=$?
    len=$(read_findings_len "$tmp" "$sid")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$len" = "1" ]; then
        pass "WL3: omit --finding-status remains backward-compatible"
    else
        fail "WL3: rc=$rc, len=$len"
    fi
}

run_wl4() {
    require_flag_supported "--confirm-finding-ids" "WL4: --confirm-finding-ids 0 promotes idx 0" || return
    local tmp sid rc status0
    tmp="$(mktemp -d)"; sid="wl4-sid"
    seed_finding "$tmp" "$sid" "draft" "d0"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --confirm-finding-ids 0 --session-id "$sid" >/dev/null 2>&1
    rc=$?
    status0=$(read_finding_field "$tmp" "$sid" 0 "status")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$status0" = '"confirmed"' ]; then
        pass "WL4: --confirm-finding-ids 0 promotes idx 0"
    else
        fail "WL4: rc=$rc, status0=$status0"
    fi
}

run_wl5() {
    require_flag_supported "--confirm-finding-ids" "WL5: --confirm-finding-ids 0,2 promotes multiple, idx 1 stays draft" || return
    local tmp sid rc s0 s1 s2
    tmp="$(mktemp -d)"; sid="wl5-sid"
    seed_finding "$tmp" "$sid" "draft" "d0"
    seed_finding "$tmp" "$sid" "draft" "d1"
    seed_finding "$tmp" "$sid" "draft" "d2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --confirm-finding-ids 0,2 --session-id "$sid" >/dev/null 2>&1
    rc=$?
    s0=$(read_finding_field "$tmp" "$sid" 0 "status")
    s1=$(read_finding_field "$tmp" "$sid" 1 "status")
    s2=$(read_finding_field "$tmp" "$sid" 2 "status")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$s0" = '"confirmed"' ] && [ "$s1" = '"draft"' ] && [ "$s2" = '"confirmed"' ]; then
        pass "WL5: --confirm-finding-ids 0,2 promotes multiple"
    else
        fail "WL5: rc=$rc s0=$s0 s1=$s1 s2=$s2"
    fi
}

run_wl6() {
    require_flag_supported "--drop-finding-ids" "WL6: --drop-finding-ids 1 removes idx 1" || return
    local tmp sid rc len d0 d1
    tmp="$(mktemp -d)"; sid="wl6-sid"
    seed_finding "$tmp" "$sid" "draft" "alpha"
    seed_finding "$tmp" "$sid" "draft" "beta"
    seed_finding "$tmp" "$sid" "draft" "gamma"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --drop-finding-ids 1 --session-id "$sid" >/dev/null 2>&1
    rc=$?
    len=$(read_findings_len "$tmp" "$sid")
    d0=$(read_finding_field "$tmp" "$sid" 0 "detail")
    d1=$(read_finding_field "$tmp" "$sid" 1 "detail")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$len" = "2" ] && [ "$d0" = '"alpha"' ] && [ "$d1" = '"gamma"' ]; then
        pass "WL6: --drop-finding-ids 1 removes idx 1"
    else
        fail "WL6: rc=$rc len=$len d0=$d0 d1=$d1"
    fi
}

run_wl7() {
    require_flag_supported "--drop-finding-ids" "WL7: --drop-finding-ids 2,0 (reverse order) descending-safe" || return
    local tmp sid rc len d0
    tmp="$(mktemp -d)"; sid="wl7-sid"
    seed_finding "$tmp" "$sid" "draft" "alpha"
    seed_finding "$tmp" "$sid" "draft" "beta"
    seed_finding "$tmp" "$sid" "draft" "gamma"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --drop-finding-ids 2,0 --session-id "$sid" >/dev/null 2>&1
    rc=$?
    len=$(read_findings_len "$tmp" "$sid")
    d0=$(read_finding_field "$tmp" "$sid" 0 "detail")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$len" = "1" ] && [ "$d0" = '"beta"' ]; then
        pass "WL7: --drop-finding-ids 2,0 descending-safe"
    else
        fail "WL7: rc=$rc len=$len d0=$d0"
    fi
}

run_wl8() {
    require_flag_supported "--confirm-finding-ids" "WL8: combined confirm+drop+set-l2-phase single call" || return
    require_flag_supported "--drop-finding-ids"   "WL8: (--drop-finding-ids)" || return
    local tmp sid rc len s0 phase
    tmp="$(mktemp -d)"; sid="wl8-sid"
    seed_finding "$tmp" "$sid" "draft" "alpha"
    seed_finding "$tmp" "$sid" "draft" "beta"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --confirm-finding-ids 0 \
        --drop-finding-ids 1 \
        --set-alert-phase done \
        --session-id "$sid" >/dev/null 2>&1
    rc=$?
    len=$(read_findings_len "$tmp" "$sid")
    s0=$(read_finding_field "$tmp" "$sid" 0 "status")
    phase=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(JSON.stringify(st && st.alert && st.alert.alert_phase));
" 2>/dev/null)
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$len" = "1" ] && [ "$s0" = '"confirmed"' ] && [ "$phase" = '"done"' ]; then
        pass "WL8: combined confirm+drop+set-l2-phase"
    else
        fail "WL8: rc=$rc len=$len s0=$s0 phase=$phase"
    fi
}

run_wl9() {
    require_flag_supported "--confirm-finding-ids" "WL9: --confirm-finding-ids non-existent idx → exit 0 graceful" || return
    local tmp sid rc
    tmp="$(mktemp -d)"; sid="wl9-sid"
    seed_finding "$tmp" "$sid" "draft" "alpha"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --confirm-finding-ids 99 --session-id "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "WL9: non-existent idx → exit 0 graceful"
    else
        fail "WL9: rc=$rc"
    fi
}

run_wl10() {
    # Empty string is not a valid CSV of integers; implementation rejects it.
    # This test verifies the --drop-finding-ids flag exists (via require_flag_supported)
    # and that legitimate single-item drop leaves other items intact.
    require_flag_supported "--drop-finding-ids" "WL10: drop leaves other findings intact" || return
    local tmp sid len
    tmp="$(mktemp -d)"; sid="wl10-sid"
    seed_finding "$tmp" "$sid" "draft" "alpha"
    seed_finding "$tmp" "$sid" "draft" "beta"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --drop-finding-ids 0 --session-id "$sid" >/dev/null 2>&1
    len=$(read_findings_len "$tmp" "$sid")
    rm -rf "$tmp"
    if [ "$len" = "1" ]; then
        pass "WL10: drop idx=0 leaves 1 remaining finding"
    else
        fail "WL10: expected 1 remaining finding, got len=$len"
    fi
}

run_wl1
run_wl2
run_wl3
run_wl4
run_wl5
run_wl6
run_wl7
run_wl8
run_wl9
run_wl10

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

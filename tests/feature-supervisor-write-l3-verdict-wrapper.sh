#!/bin/bash
# tests/feature-supervisor-write-l3-verdict-wrapper.sh
# Tests: bin/supervisor-write-l3-verdict
# Tags: supervisor, em-supervisor, layer3, wrapper, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event firing — tests invoke wrapper directly, not via hook registration
# - WORKFLOW_SESSION_ID propagation into a live session (Anthropic bug #27987)
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-l3-verdict"
CLI_NODE="$_AGENTS_DIR_NODE/bin/supervisor-write-l3-verdict"
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

read_field() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.layer3) { process.stdout.write('MISSING'); process.exit(0); }
process.stdout.write(String(st.layer3.$field));
" 2>/dev/null
}

# Skip-gate: wrapper not yet created
if [ ! -f "$CLI" ]; then
    skip "V1: valid CONTINUE -> l3_phase=done, l3_verdict=CONTINUE, l3_cause set, exit 0 (wrapper not yet created)"
    skip "V2: valid WARN -> l3_verdict=WARN (wrapper not yet created)"
    skip "V3: valid BLOCK -> l3_verdict=BLOCK (wrapper not yet created)"
    skip "V4: invalid verdict MAYBE -> non-zero exit, stderr mentions valid verdicts (wrapper not yet created)"
    skip "V5: missing cause arg (only 1 positional) -> non-zero exit (wrapper not yet created)"
    skip "V6: --session-id pass-through -> writes to named store only (wrapper not yet created)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# V1 — valid CONTINUE: l3_phase=done, l3_verdict=CONTINUE, l3_cause set, exit 0.
run_v1() {
    local label="V1: valid CONTINUE -> l3_phase=done, l3_verdict=CONTINUE, l3_cause set, exit 0"
    local tmp rc l3_phase l3_verdict l3_cause
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        CONTINUE "all checks passed" --session-id sid-v1 >/dev/null 2>&1
    rc=$?
    l3_phase=$(read_field "$tmp" "sid-v1" "l3_phase")
    l3_verdict=$(read_field "$tmp" "sid-v1" "l3_verdict")
    l3_cause=$(read_field "$tmp" "sid-v1" "l3_cause")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$l3_phase" = "done" ] && [ "$l3_verdict" = "CONTINUE" ] && [ "$l3_cause" = "all checks passed" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_phase=$l3_phase, l3_verdict=$l3_verdict, l3_cause=$l3_cause)"
    fi
}

# V2 — valid WARN: l3_verdict=WARN.
run_v2() {
    local label="V2: valid WARN -> l3_verdict=WARN"
    local tmp rc l3_verdict
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        WARN "minor concern detected" --session-id sid-v2 >/dev/null 2>&1
    rc=$?
    l3_verdict=$(read_field "$tmp" "sid-v2" "l3_verdict")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$l3_verdict" = "WARN" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_verdict=$l3_verdict)"
    fi
}

# V3 — valid BLOCK: l3_verdict=BLOCK.
run_v3() {
    local label="V3: valid BLOCK -> l3_verdict=BLOCK"
    local tmp rc l3_verdict
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        BLOCK "critical security issue" --session-id sid-v3 >/dev/null 2>&1
    rc=$?
    l3_verdict=$(read_field "$tmp" "sid-v3" "l3_verdict")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$l3_verdict" = "BLOCK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_verdict=$l3_verdict)"
    fi
}

# V4 — invalid verdict "MAYBE": non-zero exit, stderr mentions valid verdicts.
run_v4() {
    local label="V4: invalid verdict MAYBE -> non-zero exit, stderr mentions valid verdicts"
    local tmp out rc
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        MAYBE "some cause" --session-id sid-v4 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ] && echo "$out" | grep -qiE 'CONTINUE|WARN|BLOCK'; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# V5 — missing cause arg (only 1 positional): non-zero exit.
run_v5() {
    local label="V5: missing cause arg (only 1 positional) -> non-zero exit"
    local tmp out rc
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        CONTINUE --session-id sid-v5 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# V6 — --session-id pass-through: writes to named store only (not auto-resolved wsid/ccuuid).
run_v6() {
    local label="V6: --session-id pass-through -> writes to named store only"
    local tmp rc exists_named exists_wsid exists_cc
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$CLI_NODE" \
        CONTINUE "pass-through test" --session-id sid-v6 >/dev/null 2>&1
    rc=$?
    exists_named=0; exists_wsid=0; exists_cc=0
    [ -f "$tmp/sid-v6-supervisor-state.json" ] && exists_named=1
    [ -f "$tmp/wsid-supervisor-state.json" ] && exists_wsid=1
    [ -f "$tmp/ccuuid-supervisor-state.json" ] && exists_cc=1
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ $exists_named -eq 1 ] && [ $exists_wsid -eq 0 ] && [ $exists_cc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, exists_named=$exists_named, exists_wsid=$exists_wsid, exists_cc=$exists_cc)"
    fi
}

run_v1
run_v2
run_v3
run_v4
run_v5
run_v6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

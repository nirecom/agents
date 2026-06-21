#!/bin/bash
# tests/feature-720-supervisor-l3-arbitrate.sh
# Tests: hooks/lib/supervisor-guard/arbitrate.js
# Tags: supervisor, em-supervisor, layer3, arbitrate, unit, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   Pure function unit test for the arbitration rule table R0-R8.
#   Does not verify integration into the live Stop-event sequence — only a real
#   claude -p session exercises the upstream collect+downstream emit pipeline.
# RED for issue #720.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SRC="$AGENTS_DIR/hooks/lib/supervisor-guard/arbitrate.js"
SRC_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-guard/arbitrate.js"

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

# Pass JSON-literal candidates; check decision and source.
assert_arbitrate() {
    local label="$1" l2_json="$2" l3_json="$3" expect_decision="$4" expect_source="$5"
    require_source "$SRC" "$label" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$SRC_NODE');
const l2 = $l2_json;
const l3 = $l3_json;
const r = m.arbitrate(l2, l3);
if (typeof r !== 'object' || r === null) { console.error('result not object'); process.exit(2); }
if (r.decision !== '$expect_decision') { console.error('decision='+r.decision+' expected $expect_decision'); process.exit(3); }
const expSrc = '$expect_source';
if (expSrc && r.source !== expSrc) { console.error('source='+r.source+' expected '+expSrc); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

run_r0() {
    assert_arbitrate "R0: both null → allow" "null" "null" "allow" ""
}

run_r1() {
    assert_arbitrate "R1: L2 BLOCK only → block,l2" '{ "verdict": "BLOCK", "reason": "l2-r" }' "null" "block" "l2"
}

run_r2() {
    assert_arbitrate "R2: L3 BLOCK only → block,l3" "null" '{ "verdict": "BLOCK", "reason": "l3-r" }' "block" "l3"
}

run_r3() {
    assert_arbitrate "R3: both BLOCK → block,both" '{ "verdict": "BLOCK", "reason": "l2-r" }' '{ "verdict": "BLOCK", "reason": "l3-r" }' "block" "both"
}

run_r4() {
    assert_arbitrate "R4: L2 BLOCK + L3 CONTINUE → block,l2" '{ "verdict": "BLOCK", "reason": "l2-r" }' '{ "verdict": "CONTINUE", "reason": "ok" }' "block" "l2"
}

run_r5() {
    assert_arbitrate "R5: L2 CONTINUE + L3 BLOCK → block,l3" '{ "verdict": "CONTINUE", "reason": "ok" }' '{ "verdict": "BLOCK", "reason": "l3-r" }' "block" "l3"
}

run_r6() {
    assert_arbitrate "R6: both WARN → warn,both" '{ "verdict": "WARN", "reason": "l2-w" }' '{ "verdict": "WARN", "reason": "l3-w" }' "warn" "both"
}

run_r7() {
    assert_arbitrate "R7: L3 null (not run) → arbitrate on L2 only" '{ "verdict": "WARN", "reason": "l2-w" }' "null" "warn" "l2"
}

run_r8() {
    assert_arbitrate "R8: L2 WARN + L3 BLOCK → block,l3" '{ "verdict": "WARN", "reason": "l2-w" }' '{ "verdict": "BLOCK", "reason": "l3-b" }' "block" "l3"
}

run_r0; run_r1; run_r2; run_r3; run_r4; run_r5; run_r6; run_r7; run_r8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

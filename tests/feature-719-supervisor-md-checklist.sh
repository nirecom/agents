#!/bin/bash
# tests/feature-719-supervisor-md-checklist.sh
# Tests: agents/supervisor.md (JD checklist content)
# Tags: supervisor, em-supervisor, agents, layer2, doc
# RED for issue #719.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

contains_i() {
    # case-insensitive literal match
    grep -qi -- "$1" "$SUPERVISOR_MD"
}

run_m1() {
    if [ -f "$SUPERVISOR_MD" ]; then
        pass "M1: agents/supervisor.md exists"
    else
        skip "M1: agents/supervisor.md exists (source not implemented yet)"
    fi
}

run_m2() {
    require_source "$SUPERVISOR_MD" "M2: contains Layer 2 + JD/checklist + 5 axes" || return
    local ok=1
    # Layer 2 heading-ish presence
    contains_i "layer 2" || { ok=0; echo "  missing: layer 2"; }
    # JD or checklist
    if ! contains_i "JD" && ! contains_i "checklist"; then
        ok=0; echo "  missing: JD or checklist"
    fi
    # 5 axes
    contains_i "intent" || { ok=0; echo "  missing: intent"; }
    contains_i "scope" || { ok=0; echo "  missing: scope"; }
    contains_i "non-goal" || { ok=0; echo "  missing: non-goal"; }
    contains_i "tacit knowledge" || { ok=0; echo "  missing: tacit knowledge"; }
    if ! contains_i "perspective" && ! grep -q "§3\|§4\|§5" "$SUPERVISOR_MD"; then
        ok=0; echo "  missing: perspective or §3/§4/§5"
    fi
    if [ $ok -eq 1 ]; then
        pass "M2: contains Layer 2 + JD/checklist + 5 axes"
    else
        fail "M2: contains Layer 2 + JD/checklist + 5 axes"
    fi
}

run_m3() {
    require_source "$SUPERVISOR_MD" "M3: mentions bin/supervisor-write-layer2 + key flags" || return
    local ok=1
    contains_i "bin/supervisor-write-layer2" || { ok=0; echo "  missing: bin/supervisor-write-layer2"; }
    contains_i -- "--cumulative-severity" || { ok=0; echo "  missing: --cumulative-severity"; }
    contains_i -- "--last-run-at" || { ok=0; echo "  missing: --last-run-at"; }
    contains_i -- "--clear-l2-armed-at" || { ok=0; echo "  missing: --clear-l2-armed-at"; }
    if [ $ok -eq 1 ]; then
        pass "M3: mentions bin/supervisor-write-layer2 + key flags"
    else
        fail "M3: mentions bin/supervisor-write-layer2 + key flags"
    fi
}

run_m4() {
    require_source "$SUPERVISOR_MD" "M4: instruction to clear l2_armed_at after wakeup" || return
    local ok=1
    contains_i "clear" || { ok=0; echo "  missing: clear"; }
    if ! contains_i "l2_armed_at" && ! contains_i "clear-l2-armed-at"; then
        ok=0; echo "  missing: l2_armed_at or clear-l2-armed-at"
    fi
    if [ $ok -eq 1 ]; then
        pass "M4: instruction to clear l2_armed_at after wakeup"
    else
        fail "M4: instruction to clear l2_armed_at after wakeup"
    fi
}

run_m1
run_m2
run_m3
run_m4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

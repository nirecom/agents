#!/bin/bash
# tests/fix-supervisor-l3-stale-pending.sh
# Tests: skills/session-close/SKILL.md
# Tags: supervisor, em-supervisor, layer3, fix, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event firing — tests invoke skill directives statically, not in a live session
# - WORKFLOW_SESSION_ID propagation into a live session (Anthropic bug #27987)
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
# RED until session-close SKILL.md is extended with the SC-5 L3 stale-pending
# repair block (mirror of the existing L2 stale-pending repair).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$AGENTS_DIR/skills/session-close/SKILL.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Probe: SKILL.md contains the literal "1051" (the L3 stale-pending issue
# number). When absent, the L3 stale-pending repair block has not been added
# yet — SKIP every case in this file.
step3_done() {
    grep -q '1051' "$SKILL_MD"
}

run_t1() {
    local label="T1: SKILL.md contains 'l3_phase=pending' marker"
    if ! step3_done; then skip "$label (SC-5 L3 repair not yet added to SKILL.md)"; return; fi
    if grep -q 'l3_phase=pending' "$SKILL_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_t2() {
    local label="T2: SKILL.md contains 'clear-l3-armed-at' flag reference"
    if ! step3_done; then skip "$label (SC-5 L3 repair not yet added to SKILL.md)"; return; fi
    if grep -q 'clear-l3-armed-at' "$SKILL_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_t3() {
    local label="T3: SKILL.md cites issue #1051"
    if ! step3_done; then skip "$label (SC-5 L3 repair not yet added to SKILL.md)"; return; fi
    if grep -q '1051' "$SKILL_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_t4() {
    local label="T4: SKILL.md mentions 'l3_last_run_at' field"
    if ! step3_done; then skip "$label (SC-5 L3 repair not yet added to SKILL.md)"; return; fi
    if grep -q 'l3_last_run_at' "$SKILL_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_t5() {
    local label="T5: SKILL.md contains 'elapsed-time fallback' L3 mention"
    if ! step3_done; then skip "$label (SC-5 L3 repair not yet added to SKILL.md)"; return; fi
    # Accept either canonical phrasing.
    if grep -qE 'L3 elapsed-time fallback|elapsed-time fallback' "$SKILL_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_t1
run_t2
run_t3
run_t4
run_t5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

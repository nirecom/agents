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
    require_source "$SUPERVISOR_MD" "M2: contains alert mode + JD/checklist + 5 axes" || return
    local ok=1
    # Layer 2 heading-ish presence
    contains_i "alert mode" || { ok=0; echo "  missing: layer 2"; }
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
        pass "M2: contains alert mode + JD/checklist + 5 axes"
    else
        fail "M2: contains alert mode + JD/checklist + 5 axes"
    fi
}

run_m3() {
    require_source "$SUPERVISOR_MD" "M3: mentions bin/supervisor-write-alert + key flags" || return
    local ok=1
    contains_i "bin/supervisor-write-alert" || { ok=0; echo "  missing: bin/supervisor-write-alert"; }
    contains_i -- "--cumulative-severity" || { ok=0; echo "  missing: --cumulative-severity"; }
    contains_i -- "--last-run-at" || { ok=0; echo "  missing: --last-run-at"; }
    contains_i -- "--clear-alert-armed-at" || { ok=0; echo "  missing: --clear-alert-armed-at"; }
    if [ $ok -eq 1 ]; then
        pass "M3: mentions bin/supervisor-write-alert + key flags"
    else
        fail "M3: mentions bin/supervisor-write-alert + key flags"
    fi
}

run_m4() {
    require_source "$SUPERVISOR_MD" "M4: instruction to clear alert_armed_at after wakeup" || return
    local ok=1
    contains_i "clear" || { ok=0; echo "  missing: clear"; }
    if ! contains_i "alert_armed_at" && ! contains_i "clear-l2-armed-at"; then
        ok=0; echo "  missing: alert_armed_at or clear-l2-armed-at"
    fi
    if [ $ok -eq 1 ]; then
        pass "M4: instruction to clear alert_armed_at after wakeup"
    else
        fail "M4: instruction to clear alert_armed_at after wakeup"
    fi
}

line_of_heading() {
    # Print line number of first line matching pattern (case-insensitive), or 0
    local pattern="$1"
    local n
    n="$(grep -n -i -m1 -- "$pattern" "$SUPERVISOR_MD" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [ -z "$n" ]; then echo 0; else echo "$n"; fi
}

run_m5() {
    require_source "$SUPERVISOR_MD" "M5: Alert mode pre-processing section structural checks" || return
    local ok=1
    local pre_ln jd_ln
    pre_ln="$(line_of_heading '^## Alert mode pre-processing')"
    jd_ln="$(line_of_heading '^## Alert mode JD Checklist')"

    if [ "$pre_ln" -eq 0 ]; then
        ok=0; echo "  missing: '## Alert mode pre-processing' heading"
    fi
    if [ "$jd_ln" -eq 0 ]; then
        ok=0; echo "  missing: '## Alert mode JD Checklist' heading"
    fi
    if [ "$pre_ln" -gt 0 ] && [ "$jd_ln" -gt 0 ]; then
        if [ "$pre_ln" -ge "$jd_ln" ]; then
            ok=0; echo "  ordering: pre-processing ($pre_ln) must come before JD checklist ($jd_ln)"
        fi
        # Extract slice between the two headings (exclusive of jd_ln itself).
        local end_ln=$((jd_ln - 1))
        local slice
        slice="$(sed -n "${pre_ln},${end_ln}p" "$SUPERVISOR_MD")"
        if ! echo "$slice" | grep -qi 'co_blocked_by'; then
            ok=0; echo "  missing in slice: co_blocked_by"
        fi
        if ! echo "$slice" | grep -q '60'; then
            ok=0; echo "  missing in slice: 60"
        fi
        if ! echo "$slice" | grep -qiE 'second|timestamp|window|s window'; then
            ok=0; echo "  missing in slice: second|timestamp|window"
        fi
        if ! echo "$slice" | grep -qi 'group'; then
            ok=0; echo "  missing in slice: group"
        fi
        if ! echo "$slice" | grep -q '10'; then
            ok=0; echo "  missing in slice: 10"
        fi
        if ! echo "$slice" | grep -qiE 'distinct|independent|different|separate'; then
            ok=0; echo "  missing in slice: distinct|independent|different|separate"
        fi
    fi

    if [ $ok -eq 1 ]; then
        pass "M5: Alert mode pre-processing section structural checks"
    else
        fail "M5: Alert mode pre-processing section structural checks"
    fi
}

run_m6() {
    require_source "$SUPERVISOR_MD" "M6: §5 Perspective causality chain tracing" || return
    local ok=1
    local p5_ln p6_ln
    p5_ln="$(grep -n -m1 -E '^5\..*Perspective' "$SUPERVISOR_MD" 2>/dev/null | head -n1 | cut -d: -f1)"
    p6_ln="$(grep -n -m1 -E '^6\.' "$SUPERVISOR_MD" 2>/dev/null | head -n1 | cut -d: -f1)"
    [ -z "$p5_ln" ] && p5_ln=0
    [ -z "$p6_ln" ] && p6_ln=0

    if [ "$p5_ln" -eq 0 ]; then
        ok=0; echo "  missing: '5. **Perspective' checklist item"
    fi
    if [ "$p6_ln" -eq 0 ]; then
        ok=0; echo "  missing: '6.' checklist item"
    fi
    if [ "$p5_ln" -gt 0 ] && [ "$p6_ln" -gt 0 ]; then
        if [ "$p5_ln" -ge "$p6_ln" ]; then
            ok=0; echo "  ordering: §5 ($p5_ln) must come before §6 ($p6_ln)"
        else
            local end_ln=$((p6_ln - 1))
            local slice
            slice="$(sed -n "${p5_ln},${end_ln}p" "$SUPERVISOR_MD")"
            if ! echo "$slice" | grep -qiE 'causality|causal chain'; then
                ok=0; echo "  missing in slice: causality|causal chain"
            fi
            if ! echo "$slice" | grep -qiE 'root cause|upstream'; then
                ok=0; echo "  missing in slice: root cause|upstream"
            fi
        fi
    fi

    if [ $ok -eq 1 ]; then
        pass "M6: §5 Perspective causality chain tracing"
    else
        fail "M6: §5 Perspective causality chain tracing"
    fi
}

run_m7() {
    require_source "$SUPERVISOR_MD" "M7: contains C3 off-proposal content (WORKTREE_OFF + off-proposal/C3)" || return
    local ok=1
    contains_i "WORKTREE_OFF" || { ok=0; echo "  missing: WORKTREE_OFF"; }
    if ! contains_i "off-proposal" && ! contains_i "C3"; then
        ok=0; echo "  missing: off-proposal or C3"
    fi
    if [ $ok -eq 1 ]; then
        pass "M7: contains C3 off-proposal content (WORKTREE_OFF + off-proposal/C3)"
    else
        fail "M7: contains C3 off-proposal content (WORKTREE_OFF + off-proposal/C3)"
    fi
}

run_m1
run_m2
run_m3
run_m4
run_m5
run_m6
run_m7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

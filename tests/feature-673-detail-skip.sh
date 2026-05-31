#!/usr/bin/env bash
# Tests: agents/detail-planner.md, skills/make-detail-plan/SKILL.md
# Tags: worktree, detail, planning, sentinel, workflow
# L1 unit tests for change ⑤ of issue #673:
# AdaCoder-style adaptive detail-plan skip.
#
# Verifies:
#   - agents/detail-planner.md describes the 3 skip conditions and the
#     <<DETAIL_SKIPPABLE_BY_PLANNER: ...>> sentinel (emitted at draft top).
#   - skills/make-detail-plan/SKILL.md detects the sentinel between step 4
#     (planner call) and step 5 (codex review loop), runs the loop with
#     MAX_EXTENSIONS=0 (1-round hardstop), and escalates on HIGH/MEDIUM.
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
DETAIL_PLANNER="$AGENTS_WORKTREE/agents/detail-planner.md"
SKILL_MD="$AGENTS_WORKTREE/skills/make-detail-plan/SKILL.md"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [[ ! -f "$DETAIL_PLANNER" ]]; then
    echo "FAIL: $DETAIL_PLANNER does not exist"
    exit 1
fi
if [[ ! -f "$SKILL_MD" ]]; then
    echo "FAIL: $SKILL_MD does not exist"
    exit 1
fi

# Probe whether change ⑤ is implemented. If not, exit 1 with a clear message
# (matches the probe pattern used by other feature-673 tests).
if ! run_with_timeout grep -q "DETAIL_SKIPPABLE_BY_PLANNER" "$DETAIL_PLANNER"; then
    echo "FAIL: detail-planner.md does not contain DETAIL_SKIPPABLE_BY_PLANNER (change ⑤ not implemented)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. detail-planner.md mentions the sentinel with double angle-brackets
# ---------------------------------------------------------------------------
if run_with_timeout grep -q "<<DETAIL_SKIPPABLE_BY_PLANNER:" "$DETAIL_PLANNER"; then
    pass "1: detail-planner.md contains <<DETAIL_SKIPPABLE_BY_PLANNER: with double angle-brackets"
else
    fail "1: <<DETAIL_SKIPPABLE_BY_PLANNER: (double angle-brackets) not found in detail-planner.md"
fi

# ---------------------------------------------------------------------------
# 2. Skip condition 1 — file paths + change content — described near sentinel
# ---------------------------------------------------------------------------
SENTINEL_LINE=$(run_with_timeout grep -n "DETAIL_SKIPPABLE_BY_PLANNER" "$DETAIL_PLANNER" | head -1 | cut -d: -f1)
if [[ -z "$SENTINEL_LINE" ]]; then
    fail "2: cannot locate DETAIL_SKIPPABLE_BY_PLANNER line in detail-planner.md"
else
    # Look in a 60-line window around the sentinel (30 before / 30 after).
    START=$((SENTINEL_LINE > 30 ? SENTINEL_LINE - 30 : 1))
    WINDOW=$(run_with_timeout sed -n "${START},$((SENTINEL_LINE + 30))p" "$DETAIL_PLANNER")
    # Condition 1: file paths + changes.
    if echo "$WINDOW" | grep -E -q -i "file path.*change|concrete file.*change|file.*and.*content|file path.*content|paths.*change content"; then
        pass "2: skip condition 1 (file paths + changes) described near sentinel"
    else
        fail "2: skip condition 1 (file paths + change content) not described in 60-line window around sentinel"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Skip condition 2 — Class members triage:MUST + concrete file mentions
# ---------------------------------------------------------------------------
if [[ -n "$SENTINEL_LINE" ]]; then
    START=$((SENTINEL_LINE > 30 ? SENTINEL_LINE - 30 : 1))
    WINDOW=$(run_with_timeout sed -n "${START},$((SENTINEL_LINE + 30))p" "$DETAIL_PLANNER")
    if echo "$WINDOW" | grep -E -q -i "(Class member|class.*member).*MUST|MUST.*(Class member|class.*member)|triage.*MUST|MUST.*triage"; then
        pass "3: skip condition 2 (Class members triage:MUST + concrete file) described near sentinel"
    else
        fail "3: skip condition 2 (Class members MUST + concrete file mentions) not described near sentinel"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Skip condition 3 — no new abstraction / no responsibility reassignment /
#    no remaining design decisions
# ---------------------------------------------------------------------------
if [[ -n "$SENTINEL_LINE" ]]; then
    START=$((SENTINEL_LINE > 30 ? SENTINEL_LINE - 30 : 1))
    WINDOW=$(run_with_timeout sed -n "${START},$((SENTINEL_LINE + 30))p" "$DETAIL_PLANNER")
    if echo "$WINDOW" | grep -E -q -i "design decision|new abstraction|responsibility.*reassign|reassign.*responsibility|no.*abstraction"; then
        pass "4: skip condition 3 (no design decision / no new abstraction / no responsibility reassignment) described"
    else
        fail "4: skip condition 3 not described in window around sentinel"
    fi
fi

# ---------------------------------------------------------------------------
# 5. detail-planner.md instructs sentinel to be emitted at draft top
# ---------------------------------------------------------------------------
if [[ -n "$SENTINEL_LINE" ]]; then
    START=$((SENTINEL_LINE > 30 ? SENTINEL_LINE - 30 : 1))
    WINDOW=$(run_with_timeout sed -n "${START},$((SENTINEL_LINE + 30))p" "$DETAIL_PLANNER")
    if echo "$WINDOW" | grep -E -q -i "top of.*draft|draft.*top|first line|before any plan|first thing|at the top|before.*plan content|beginning of the draft"; then
        pass "5: detail-planner.md instructs sentinel emission at draft top / first thing"
    else
        fail "5: 'sentinel at draft top / first thing emitted' not described near sentinel"
    fi
fi

# ---------------------------------------------------------------------------
# 6. SKILL.md contains DETAIL_SKIPPABLE_BY_PLANNER detection text
# ---------------------------------------------------------------------------
if run_with_timeout grep -q "DETAIL_SKIPPABLE_BY_PLANNER" "$SKILL_MD"; then
    pass "6: SKILL.md contains DETAIL_SKIPPABLE_BY_PLANNER detection text"
else
    fail "6: SKILL.md does not mention DETAIL_SKIPPABLE_BY_PLANNER"
fi

# ---------------------------------------------------------------------------
# 7. SKILL.md mentions MAX_EXTENSIONS=0
# ---------------------------------------------------------------------------
if run_with_timeout grep -q "MAX_EXTENSIONS=0" "$SKILL_MD"; then
    pass "7: SKILL.md mentions MAX_EXTENSIONS=0"
else
    fail "7: SKILL.md does not mention MAX_EXTENSIONS=0"
fi

# ---------------------------------------------------------------------------
# 8. Sentinel detection in SKILL.md is AFTER step 4 (planner call)
# ---------------------------------------------------------------------------
SKIPPABLE_LINE=$(run_with_timeout grep -n "DETAIL_SKIPPABLE_BY_PLANNER" "$SKILL_MD" | head -1 | cut -d: -f1)
STEP4_LINE=$(run_with_timeout grep -E -n -i "^4\.|step 4|^### 4 |^## 4 " "$SKILL_MD" | head -1 | cut -d: -f1)
if [[ -z "$SKIPPABLE_LINE" ]]; then
    fail "8: cannot find DETAIL_SKIPPABLE_BY_PLANNER in SKILL.md"
elif [[ -z "$STEP4_LINE" ]]; then
    fail "8: cannot locate step 4 marker in SKILL.md"
elif [[ "$SKIPPABLE_LINE" -gt "$STEP4_LINE" ]]; then
    pass "8: sentinel detection (line $SKIPPABLE_LINE) is AFTER step 4 (line $STEP4_LINE)"
else
    fail "8: sentinel detection (line $SKIPPABLE_LINE) is NOT after step 4 (line $STEP4_LINE)"
fi

# ---------------------------------------------------------------------------
# 9. Sentinel detection in SKILL.md is BEFORE step 5 (codex review loop)
# ---------------------------------------------------------------------------
STEP5_LINE=$(run_with_timeout grep -E -n -i "^5\.|step 5|^### 5 |^## 5 " "$SKILL_MD" | head -1 | cut -d: -f1)
if [[ -z "$SKIPPABLE_LINE" ]]; then
    fail "9: cannot find DETAIL_SKIPPABLE_BY_PLANNER in SKILL.md"
elif [[ -z "$STEP5_LINE" ]]; then
    fail "9: cannot locate step 5 marker in SKILL.md"
elif [[ "$SKIPPABLE_LINE" -lt "$STEP5_LINE" ]]; then
    pass "9: sentinel detection (line $SKIPPABLE_LINE) is BEFORE step 5 (line $STEP5_LINE)"
else
    fail "9: sentinel detection (line $SKIPPABLE_LINE) is NOT before step 5 (line $STEP5_LINE)"
fi

# ---------------------------------------------------------------------------
# 10. SKILL.md mentions 1-round hardstop in the sentinel path
# ---------------------------------------------------------------------------
if run_with_timeout grep -E -q -i "hardstop|1.round|one.round|MAX_EXTENSIONS=0" "$SKILL_MD"; then
    pass "10: SKILL.md mentions 1-round hardstop (hardstop/1-round/one-round/MAX_EXTENSIONS=0)"
else
    fail "10: SKILL.md does not mention 1-round hardstop"
fi

# ---------------------------------------------------------------------------
# 11. SKILL.md mentions ESCALATE in context of HIGH or MEDIUM residual
# ---------------------------------------------------------------------------
if [[ -n "$SKIPPABLE_LINE" ]]; then
    # Window: from the sentinel line to 80 lines after.
    WIN=$(run_with_timeout sed -n "${SKIPPABLE_LINE},$((SKIPPABLE_LINE + 80))p" "$SKILL_MD")
    if echo "$WIN" | grep -q "ESCALATE" && echo "$WIN" | grep -E -q "HIGH|MEDIUM"; then
        pass "11: SKILL.md mentions ESCALATE with HIGH/MEDIUM residual in sentinel-path window"
    else
        fail "11: ESCALATE + HIGH/MEDIUM not found in 80-line window after sentinel detection in SKILL.md"
    fi
else
    fail "11: cannot locate sentinel line in SKILL.md to check ESCALATE context"
fi

# ---------------------------------------------------------------------------
# 12. detail-planner.md has ≥ 3 numbered skip conditions near the sentinel
# ---------------------------------------------------------------------------
if [[ -n "$SENTINEL_LINE" ]]; then
    # Take 30 lines AFTER the first sentinel mention.
    WIN_AFTER=$(run_with_timeout sed -n "${SENTINEL_LINE},$((SENTINEL_LINE + 30))p" "$DETAIL_PLANNER")
    NUM_BULLETS=$(echo "$WIN_AFTER" | grep -E -c "^[[:space:]]*[1-9][0-9]*[.)]" || true)
    if [[ "$NUM_BULLETS" -ge 3 ]]; then
        pass "12: ≥ 3 numbered items found in 30-line window after sentinel (found $NUM_BULLETS)"
    else
        fail "12: expected ≥ 3 numbered skip conditions near sentinel; found $NUM_BULLETS"
    fi
else
    fail "12: cannot locate sentinel line in detail-planner.md"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi

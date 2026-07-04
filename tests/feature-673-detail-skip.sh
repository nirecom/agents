#!/usr/bin/env bash
# Tests: agents/detail-planner.md, skills/make-detail-plan/SKILL.md
# Tags: worktree, detail, planning, sentinel, workflow
# L1 unit tests for change ⑤ of issue #673 as superseded by #1286:
# #673 introduced adaptive detail-plan skip via DETAIL_SKIPPABLE_BY_PLANNER.
# #1286 changed MDP-4a so that sentinel is now a fallback notice only:
#   no MAX_EXTENSIONS=0 hardstop; MDP-5 proceeds normally.
#   The authoritative skip is now the pre-flight recorded-verdict path
#   (MOP-C1 / CI-C1b), consumed by bin/workflow/next-step + gate logic.
#
# Verifies:
#   - agents/detail-planner.md describes the 3 skip conditions and the
#     <<DETAIL_SKIPPABLE_BY_PLANNER: ...>> sentinel (emitted at draft top).
#   - skills/make-detail-plan/SKILL.md MDP-4a treats the sentinel as a
#     fallback notice (no adaptive skip, no hardstop, proceed to MDP-5).
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
# 7. SKILL.md MDP-4a uses fallback-notice language (not adaptive-skip)
#    Must contain "fallback notice" AND either "Do NOT set MAX_EXTENSIONS=0"
#    or "Proceed to MDP-5 normally". Fails if MDP-4a reverts to adaptive skip.
# ---------------------------------------------------------------------------
MDP4A_SECTION=$(run_with_timeout grep -A 5 "Step MDP-4a" "$SKILL_MD" || true)
if echo "$MDP4A_SECTION" | grep -q "fallback notice" && \
   echo "$MDP4A_SECTION" | grep -E -q "Do NOT set MAX_EXTENSIONS=0|Proceed to MDP-5 normally"; then
    pass "7: SKILL.md MDP-4a contains fallback-notice semantics (not adaptive-skip)"
else
    fail "7: SKILL.md MDP-4a missing fallback-notice semantics — expected 'fallback notice' AND ('Do NOT set MAX_EXTENSIONS=0' OR 'Proceed to MDP-5 normally')"
fi

# ---------------------------------------------------------------------------
# 8. Sentinel detection in SKILL.md is AFTER MDP-4 planner-call heading
#    Anchored to "### Step MDP-4 " (with trailing space) so MDP-4a is excluded.
# ---------------------------------------------------------------------------
SKIPPABLE_LINE=$(run_with_timeout grep -n "DETAIL_SKIPPABLE_BY_PLANNER" "$SKILL_MD" | head -1 | cut -d: -f1)
STEP4_LINE=$(run_with_timeout grep -n "^### Step MDP-4 " "$SKILL_MD" | head -1 | cut -d: -f1)
if [[ -z "$SKIPPABLE_LINE" ]]; then
    fail "8: cannot find DETAIL_SKIPPABLE_BY_PLANNER in SKILL.md"
elif [[ -z "$STEP4_LINE" ]]; then
    fail "8: cannot locate '### Step MDP-4 ' heading in SKILL.md"
elif [[ "$SKIPPABLE_LINE" -gt "$STEP4_LINE" ]]; then
    pass "8: sentinel detection (line $SKIPPABLE_LINE) is AFTER MDP-4 (line $STEP4_LINE)"
else
    fail "8: sentinel detection (line $SKIPPABLE_LINE) is NOT after MDP-4 (line $STEP4_LINE)"
fi

# ---------------------------------------------------------------------------
# 9. Sentinel detection in SKILL.md is BEFORE MDP-5 codex-review-loop heading
#    Anchored to "### Step MDP-5 " heading.
# ---------------------------------------------------------------------------
STEP5_LINE=$(run_with_timeout grep -n "^### Step MDP-5 " "$SKILL_MD" | head -1 | cut -d: -f1)
if [[ -z "$SKIPPABLE_LINE" ]]; then
    fail "9: cannot find DETAIL_SKIPPABLE_BY_PLANNER in SKILL.md"
elif [[ -z "$STEP5_LINE" ]]; then
    fail "9: cannot locate '### Step MDP-5 ' heading in SKILL.md"
elif [[ "$SKIPPABLE_LINE" -lt "$STEP5_LINE" ]]; then
    pass "9: sentinel detection (line $SKIPPABLE_LINE) is BEFORE MDP-5 (line $STEP5_LINE)"
else
    fail "9: sentinel detection (line $SKIPPABLE_LINE) is NOT before MDP-5 (line $STEP5_LINE)"
fi

# ---------------------------------------------------------------------------
# 10. SKILL.md MDP-4a instructs proceeding to MDP-5 normally (no adaptive skip)
#     The sentinel path must NOT set MAX_EXTENSIONS=0 and must instruct normal
#     continuation. Asserts the new #1286 semantics are present.
# ---------------------------------------------------------------------------
MDP4A_FULL=$(run_with_timeout grep -A 5 "Step MDP-4a" "$SKILL_MD" || true)
if echo "$MDP4A_FULL" | grep -E -q "Proceed to MDP-5 normally|MDP-5 unchanged"; then
    pass "10: SKILL.md MDP-4a instructs normal MDP-5 continuation (no adaptive-skip hardstop)"
else
    fail "10: SKILL.md MDP-4a missing 'Proceed to MDP-5 normally' or 'MDP-5 unchanged' instruction"
fi

# ---------------------------------------------------------------------------
# 11. agents/detail-planner.md §0 states the 3 conditions are evaluated
#     pre-flight (MOP-C1 / CI-C1b) and the sentinel is only a fallback notice.
#     Asserts the #1286 recorded-verdict path description is present.
# ---------------------------------------------------------------------------
DETAIL_PLANNER_NOTE=$(run_with_timeout grep -i "fallback notice\|pre-flight\|MOP-C1\|CI-C1b" "$DETAIL_PLANNER" || true)
if [[ -n "$DETAIL_PLANNER_NOTE" ]]; then
    pass "11: detail-planner.md §0 documents pre-flight evaluation (MOP-C1/CI-C1b) and fallback-notice semantics"
else
    fail "11: detail-planner.md §0 missing pre-flight / fallback-notice language (MOP-C1 / CI-C1b / 'fallback notice')"
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

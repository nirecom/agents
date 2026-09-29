# Tests: skills/make-outline-plan/SKILL.md, skills/_shared/codex-review-loop.md, agents/outline-planner.md
# Tags: outline, planning, skill, scope:common
# Issue #329 accepted-tradeoffs and Issue #462 assemble-mandatory cases.
# Sourced by tests/agents/feature-make-outline-plan.sh.

# ---------------------------------------------------------------------------
# Issue #329: Accepted Tradeoffs section + carry-over log symmetry
# ---------------------------------------------------------------------------
case_begin "Issue 329 accepted-tradeoffs" "skills/make-outline-plan/SKILL.md"

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_REPO="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
PLANNER_REPO="$AGENTS_ROOT/agents/outline-planner.md"

# #329-1: Accepted Tradeoffs section in SKILL.md
if grep -qF "Accepted Tradeoffs" "$SKILL_REPO" 2>/dev/null; then
    pass "#329-1: 'Accepted Tradeoffs' section present in make-outline-plan/SKILL.md"
else
    fail "#329-1" "'Accepted Tradeoffs' section missing from make-outline-plan/SKILL.md"
fi

# #329-2: Accepted Tradeoffs section in outline-planner.md
if grep -qF "Accepted Tradeoffs" "$PLANNER_REPO" 2>/dev/null; then
    pass "#329-2: 'Accepted Tradeoffs' section present in agents/outline-planner.md"
else
    fail "#329-2" "'Accepted Tradeoffs' section missing from agents/outline-planner.md"
fi

# #329-3: round-log + planner-response trailer mechanism. After the _shared/
# extraction, the SKILL.md references skills/_shared/codex-review-loop.md and
# the shared spec carries the round-log / planner-response wording (SSOT).
SHARED_LOOP="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"
if grep -qF "_shared/codex-review-loop.md" "$SKILL_REPO" 2>/dev/null && \
   grep -qE "round.*log|planner-response" "$SHARED_LOOP" 2>/dev/null; then
    pass "#329-3: SKILL.md references _shared/codex-review-loop.md; shared spec covers round-log / planner-response"
else
    fail "#329-3" "SKILL.md must reference _shared/codex-review-loop.md, and shared spec must cover round-log / planner-response"
fi

case_end
echo ""
# ---------------------------------------------------------------------------
# Issue #462: assemble-mandatory.sh mechanical injection checks
# ---------------------------------------------------------------------------
case_begin "Issue 462 assemble-mandatory" "skills/make-outline-plan/SKILL.md"

AGENTS_ROOT_462="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_462="$AGENTS_ROOT_462/skills/make-outline-plan/SKILL.md"

# M10: assemble-mandatory.sh called in SKILL.md
if grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M10: assemble-mandatory.sh referenced in make-outline-plan/SKILL.md"
else
    fail "M10" "assemble-mandatory.sh NOT referenced in make-outline-plan/SKILL.md"
fi

# M11: SINGLE_APPROACH_JUSTIFIED path also uses assemble-mandatory.sh
# (Both SINGLE_APPROACH_JUSTIFIED and assemble-mandatory must appear in the same file.)
if grep -q "SINGLE_APPROACH_JUSTIFIED" "$SKILL_462" 2>/dev/null && \
   grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M11: SINGLE_APPROACH_JUSTIFIED path and assemble-mandatory.sh both present in SKILL.md"
else
    fail "M11" "SINGLE_APPROACH_JUSTIFIED or assemble-mandatory.sh missing from SKILL.md"
fi

# M12a: planner-side contract present (do not write mandatory sections; authored copies stripped).
# Wording moved away from the direct translation "machine-injected"; the contract — that the
# orchestrator carries these sections and the planner must not write them — must remain.
if grep -qE "[Dd]o NOT (instruct the planner to )?(author|write)|[Dd]o not (instruct the planner to )?(author|write)|planner.authored copies (will be|are) stripped|helper carries them forward" "$SKILL_462" 2>/dev/null; then
    pass "M12a: planner-side 'do not write / authored copies stripped' contract present in make-outline-plan/SKILL.md"
else
    fail "M12a" "SKILL.md missing the planner-side contract (do not write mandatory sections / authored copies are stripped)"
fi

# M12b: no verbatim-copy instruction (machine-injection replaces manual copy)
if ! grep -qE "verbatim.copy|copy.*verbatim" "$SKILL_462" 2>/dev/null; then
    pass "M12b: no 'verbatim copy' instruction in make-outline-plan/SKILL.md (machine-injection replaces it)"
else
    fail "M12b" "'verbatim copy' instruction still present in SKILL.md — should be removed"
fi

case_end
echo ""

#!/bin/bash
# Tests: skills/_shared/confirm-plan.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md
# Tags: confirm-plan, co-emission, sentinel, outline, detail, intent, ssot
# Static grep-based checks verifying that #842 co-emission wiring is in place:
#   - confirm-plan.md documents the MUST co-emit requirement
#   - each skill references the co-emission requirement via confirm-plan.md Step 3
#   - make-outline-plan Completion emits both WORKFLOW_MARK_STEP_outline_complete AND
#     WORKFLOW_OUTLINE_PLAN_COMPLETE before calling make-detail-plan (co-emission)
#   - make-detail-plan ON path emits WORKFLOW_MARK_STEP_detail_complete after confirm
#
# Pre-implementation: assertions about "MUST be co-emitted" and "confirm-plan.md Step 3"
# references are expected to FAIL until source files are updated.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# grep wrapper: fixed-string match, returns 0/1
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}

# grep wrapper: extended regex match, returns 0/1
has() {
    grep -E -- "$1" "$2" >/dev/null 2>&1
}

CONFIRM_PLAN_MD="$REPO_ROOT/skills/_shared/confirm-plan.md"
CLARIFY_INTENT_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"
OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 1. confirm-plan.md documents the co-emission preferred path + structural fallback
# ---------------------------------------------------------------------------
echo "=== 1. confirm-plan.md: co-emission directive + structural fallback ==="
if require_file "$CONFIRM_PLAN_MD"; then
    if has_fixed "Co-emission (preferred path)" "$CONFIRM_PLAN_MD"; then
        pass "confirm-plan.md documents 'Co-emission (preferred path)'"
    else
        fail "confirm-plan.md missing 'Co-emission (preferred path)' directive"
    fi
    if has_fixed "Structural fallback" "$CONFIRM_PLAN_MD" && has_fixed "workflow-mark.js" "$CONFIRM_PLAN_MD"; then
        pass "confirm-plan.md cites Structural fallback + workflow-mark.js"
    else
        fail "confirm-plan.md missing 'Structural fallback' + workflow-mark.js reference"
    fi
fi

# ---------------------------------------------------------------------------
# 2. clarify-intent/SKILL.md: co-emission reference near WORKFLOW_CONFIRM_INTENT
# ---------------------------------------------------------------------------
echo "=== 2. clarify-intent/SKILL.md: co-emission reference ==="
if require_file "$CLARIFY_INTENT_SKILL"; then
    if has "co-emit|confirm-plan\.md Step 3" "$CLARIFY_INTENT_SKILL"; then
        pass "clarify-intent/SKILL.md references co-emit or confirm-plan.md Step 3"
    else
        fail "clarify-intent/SKILL.md missing co-emit / confirm-plan.md Step 3 reference"
    fi
fi

# ---------------------------------------------------------------------------
# 3. make-outline-plan/SKILL.md Completion: co-emits mark_step AND plan_complete
#    AND invokes make-detail-plan
# ---------------------------------------------------------------------------
echo "=== 3. make-outline-plan/SKILL.md: Completion co-emission ==="
if require_file "$OUTLINE_SKILL"; then
    if has_fixed "WORKFLOW_MARK_STEP_outline_complete" "$OUTLINE_SKILL"; then
        pass "make-outline-plan/SKILL.md references WORKFLOW_MARK_STEP_outline_complete"
    else
        fail "make-outline-plan/SKILL.md missing WORKFLOW_MARK_STEP_outline_complete"
    fi

    if has_fixed "WORKFLOW_OUTLINE_PLAN_COMPLETE" "$OUTLINE_SKILL"; then
        pass "make-outline-plan/SKILL.md references WORKFLOW_OUTLINE_PLAN_COMPLETE"
    else
        fail "make-outline-plan/SKILL.md missing WORKFLOW_OUTLINE_PLAN_COMPLETE"
    fi

    if has_fixed "make-detail-plan" "$OUTLINE_SKILL"; then
        pass "make-outline-plan/SKILL.md references make-detail-plan"
    else
        fail "make-outline-plan/SKILL.md missing make-detail-plan reference"
    fi
fi

# ---------------------------------------------------------------------------
# 4. make-detail-plan/SKILL.md: WORKFLOW_MARK_STEP_detail_complete near CONFIRM_DETAIL
# ---------------------------------------------------------------------------
echo "=== 4. make-detail-plan/SKILL.md: detail_complete near CONFIRM_DETAIL ==="
if require_file "$DETAIL_SKILL"; then
    if has_fixed "WORKFLOW_MARK_STEP_detail_complete" "$DETAIL_SKILL"; then
        pass "make-detail-plan/SKILL.md references WORKFLOW_MARK_STEP_detail_complete"
    else
        fail "make-detail-plan/SKILL.md missing WORKFLOW_MARK_STEP_detail_complete"
    fi
fi

# ---------------------------------------------------------------------------
# 5. SSOT pointer: each skill references "confirm-plan.md Step 3"
#    (rules/prompt.md §3.2 — no-echo-in-references: pointer only, not duplicate content)
# ---------------------------------------------------------------------------
echo "=== 5. SSOT pointer: skills reference 'confirm-plan.md Step 3' ==="
for skill_file in "$CLARIFY_INTENT_SKILL" "$OUTLINE_SKILL" "$DETAIL_SKILL"; do
    skill_name="$(basename "$(dirname "$skill_file")")"
    if require_file "$skill_file"; then
        if has_fixed "confirm-plan.md Step 3" "$skill_file"; then
            pass "$skill_name/SKILL.md references 'confirm-plan.md Step 3'"
        else
            fail "$skill_name/SKILL.md missing 'confirm-plan.md Step 3' SSOT pointer"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 6. Structural enforcement: workflow-mark.js wires the CONFIRM next-step handler
#    so the workflow continues even when the LLM does NOT co-emit follow-up calls.
# ---------------------------------------------------------------------------
echo "=== 6. workflow-mark.js: CONFIRM next-step handler wired ==="
HANDLER_FILE="$REPO_ROOT/hooks/workflow-mark/confirm-next-step-handler.js"
WORKFLOW_MARK="$REPO_ROOT/hooks/workflow-mark.js"
SENTINEL_PATTERNS="$REPO_ROOT/hooks/lib/sentinel-patterns.js"
WORKFLOW_STATE="$REPO_ROOT/hooks/lib/workflow-state.js"

if require_file "$HANDLER_FILE"; then
    if has_fixed "CONFIRM_INTENT_RE_DQ" "$HANDLER_FILE" \
       && has_fixed "CONFIRM_OUTLINE_RE_DQ" "$HANDLER_FILE" \
       && has_fixed "CONFIRM_DETAIL_RE_DQ" "$HANDLER_FILE"; then
        pass "confirm-next-step-handler.js dispatches all three CONFIRM stages"
    else
        fail "confirm-next-step-handler.js missing one of CONFIRM_{INTENT,OUTLINE,DETAIL}_RE_DQ"
    fi
fi

if require_file "$WORKFLOW_MARK"; then
    if has_fixed "confirm-next-step-handler" "$WORKFLOW_MARK"; then
        pass "workflow-mark.js requires confirm-next-step-handler"
    else
        fail "workflow-mark.js does NOT require confirm-next-step-handler"
    fi
    if has "confirmNextStepHandler\.handle" "$WORKFLOW_MARK"; then
        pass "workflow-mark.js invokes confirmNextStepHandler.handle in dispatch"
    else
        fail "workflow-mark.js missing confirmNextStepHandler.handle dispatch call"
    fi
fi

if require_file "$SENTINEL_PATTERNS"; then
    if has_fixed "CONFIRM_INTENT_RE_DQ" "$SENTINEL_PATTERNS" \
       && has_fixed "CONFIRM_OUTLINE_RE_DQ" "$SENTINEL_PATTERNS" \
       && has_fixed "CONFIRM_DETAIL_RE_DQ" "$SENTINEL_PATTERNS"; then
        pass "sentinel-patterns.js defines all three CONFIRM_*_RE_DQ regexes"
    else
        fail "sentinel-patterns.js missing one of CONFIRM_{INTENT,OUTLINE,DETAIL}_RE_DQ"
    fi
fi

if require_file "$WORKFLOW_STATE"; then
    if has_fixed "confirmNextStepHint" "$WORKFLOW_STATE" \
       && has_fixed "CONFIRM_NEXT_STEP_HINT" "$WORKFLOW_STATE"; then
        pass "workflow-state.js exports confirmNextStepHint + table"
    else
        fail "workflow-state.js missing confirmNextStepHint or CONFIRM_NEXT_STEP_HINT"
    fi
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed."
    exit 0
else
    echo "$ERRORS check(s) failed."
    exit 1
fi

#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, hooks/stop-confirm-plan-guard.js, hooks/lib/sentinel-patterns.js
# Tags: confirm-plan, sentinel, outline, detail, intent, structural-fallback, stop-guard
# Static grep-based checks verifying that #842 structural wiring is in place:
#   - make-outline-plan Completion emits both WORKFLOW_MARK_STEP_outline_complete AND
#     WORKFLOW_OUTLINE_PLAN_COMPLETE before calling make-detail-plan
#   - make-detail-plan ON path emits WORKFLOW_MARK_STEP_detail_complete after confirm
#   - Each caller invokes the skills/_shared/confirm-plan.md protocol
#   - stop-confirm-plan-guard.js Layer 2 references CONFIRM_<STAGE>_RE_DQ for all three stages
#   - sentinel-patterns.js no longer carries the legacy "workflow-mark.js injects" comment
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
# 3. make-outline-plan/SKILL.md Completion: emits mark_step AND plan_complete
#    AND invokes make-detail-plan
# ---------------------------------------------------------------------------
echo "=== 3. make-outline-plan/SKILL.md: Completion sentinels ==="
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
# 5. Each caller invokes the confirm-plan protocol (generic SSOT reference;
#    no per-caller "Step 3" pointer required — protocol handles it internally)
# ---------------------------------------------------------------------------
echo "=== 5. Each caller invokes skills/_shared/confirm-plan.md protocol ==="
for skill_file in "$CLARIFY_INTENT_SKILL" "$OUTLINE_SKILL" "$DETAIL_SKILL"; do
    skill_name="$(basename "$(dirname "$skill_file")")"
    if require_file "$skill_file"; then
        if has_fixed "skills/_shared/confirm-plan.md" "$skill_file"; then
            pass "$skill_name/SKILL.md invokes skills/_shared/confirm-plan.md"
        else
            fail "$skill_name/SKILL.md missing skills/_shared/confirm-plan.md invocation"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 7. stop-confirm-plan-guard.js Layer 2: references all three CONFIRM_<STAGE>_RE_DQ
#    constants so it can dispatch follow-up checks per stage.
# ---------------------------------------------------------------------------
echo "=== 7. stop-confirm-plan-guard.js: CONFIRM_<STAGE>_RE_DQ references ==="
STOP_GUARD="$REPO_ROOT/hooks/stop-confirm-plan-guard.js"
if require_file "$STOP_GUARD"; then
    if has_fixed "CONFIRM_INTENT_RE_DQ" "$STOP_GUARD" \
       && has_fixed "CONFIRM_OUTLINE_RE_DQ" "$STOP_GUARD" \
       && has_fixed "CONFIRM_DETAIL_RE_DQ" "$STOP_GUARD"; then
        pass "stop-confirm-plan-guard.js references all three CONFIRM_<STAGE>_RE_DQ"
    else
        fail "stop-confirm-plan-guard.js missing one of CONFIRM_{INTENT,OUTLINE,DETAIL}_RE_DQ"
    fi
fi

# ---------------------------------------------------------------------------
# 8. sentinel-patterns.js no longer carries the legacy "workflow-mark.js injects"
#    doc comment (the additionalContext injection path was removed in #842).
# ---------------------------------------------------------------------------
echo "=== 8. sentinel-patterns.js: legacy doc comment removed ==="
SENTINEL_PATTERNS="$REPO_ROOT/hooks/lib/sentinel-patterns.js"
if require_file "$SENTINEL_PATTERNS"; then
    if has_fixed "workflow-mark.js injects" "$SENTINEL_PATTERNS"; then
        fail "sentinel-patterns.js still contains 'workflow-mark.js injects' doc string"
    else
        pass "sentinel-patterns.js does not contain 'workflow-mark.js injects'"
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

#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, hooks/stop-confirm-plan-guard.js, hooks/lib/sentinel-patterns.js, skills/commit-push/SKILL.md
# Tags: confirm-plan, sentinel, outline, detail, intent, structural-fallback, stop-guard
# Static grep-based checks verifying that #842 structural wiring is in place:
#   - make-outline-plan Completion emits WORKFLOW_MARK_STEP_outline_complete before calling make-detail-plan
#   - make-detail-plan ON path emits WORKFLOW_MARK_STEP_detail_complete after confirm
#   - Each caller invokes the skills/_shared/confirm-plan.md protocol
#   - stop-confirm-plan-guard.js Layer 2 references CONFIRM_<STAGE>_RE_DQ for all three stages
#   - sentinel-patterns.js no longer carries the legacy "workflow-mark.js injects" comment
#
# L3 gap (what this test does NOT catch):
# - whether CONFIRM_<STAGE> sentinel + co-emitted Skill actually prevents a stall in a live session
#   (hook registration wiring — only verifiable via live claude -p run)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
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
# 3. make-outline-plan/SKILL.md Completion: emits mark_step
#    AND invokes make-detail-plan
# ---------------------------------------------------------------------------
echo "=== 3. make-outline-plan/SKILL.md: Completion sentinels ==="
if require_file "$OUTLINE_SKILL"; then
    if has_fixed "WORKFLOW_MARK_STEP_outline_complete" "$OUTLINE_SKILL"; then
        pass "make-outline-plan/SKILL.md references WORKFLOW_MARK_STEP_outline_complete"
    else
        fail "make-outline-plan/SKILL.md missing WORKFLOW_MARK_STEP_outline_complete"
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
# 7. stop-confirm-plan-guard.js Layer 2: references all CONFIRM_<STAGE>_RE_DQ
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
# Case A: commit-push/SKILL.md must NOT contain WORKFLOW_CONFIRM_PR_CREATED
# ---------------------------------------------------------------------------
echo "=== Case A: commit-push/SKILL.md: WORKFLOW_CONFIRM_PR_CREATED absent ==="
COMMIT_PUSH_SKILL="$REPO_ROOT/skills/commit-push/SKILL.md"
if require_file "$COMMIT_PUSH_SKILL"; then
    if has_fixed "WORKFLOW_CONFIRM_PR_CREATED" "$COMMIT_PUSH_SKILL"; then
        fail "commit-push/SKILL.md still contains WORKFLOW_CONFIRM_PR_CREATED (sentinel not removed)"
    else
        pass "commit-push/SKILL.md: WORKFLOW_CONFIRM_PR_CREATED absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case B: commit-push/SKILL.md Step 7(a) on-mode references /worktree-end
#         (documents that WF-CODE-11 owns worktree-end invocation, not CONFIRM)
# ---------------------------------------------------------------------------
echo "=== Case B: commit-push/SKILL.md on-mode references /worktree-end ==="
if require_file "$COMMIT_PUSH_SKILL"; then
    if has_fixed "worktree-end" "$COMMIT_PUSH_SKILL"; then
        pass "commit-push/SKILL.md references /worktree-end in on-mode step"
    else
        fail "commit-push/SKILL.md missing /worktree-end reference"
    fi
fi

# ---------------------------------------------------------------------------
# Case C: commit-push/SKILL.md must NOT contain Step 6.5 or PR-created heading
# ---------------------------------------------------------------------------
echo "=== Case C: commit-push/SKILL.md: no Step 6.5 / PR-created heading ==="
if require_file "$COMMIT_PUSH_SKILL"; then
    if has_fixed "6.5." "$COMMIT_PUSH_SKILL" || has_fixed "PR-created confirmation" "$COMMIT_PUSH_SKILL"; then
        fail "commit-push/SKILL.md still contains Step 6.5 or PR-created confirmation heading"
    else
        pass "commit-push/SKILL.md: Step 6.5 and PR-created heading absent"
    fi
fi

# ---------------------------------------------------------------------------
# 12. skills/_shared/confirm-plan.md: has co-emit imperative wording so
#     callers know CONFIRM_<STAGE> and the follow-up Skill must be emitted
#     in the same assistant response.
# ---------------------------------------------------------------------------
echo "=== 12. skills/_shared/confirm-plan.md: co-emit imperative wording ==="
CONFIRM_PLAN="$REPO_ROOT/skills/_shared/confirm-plan.md"
if require_file "$CONFIRM_PLAN"; then
    if has "SAME response|co-emit" "$CONFIRM_PLAN"; then
        pass "confirm-plan.md has co-emit / same response wording"
    else
        fail "confirm-plan.md missing co-emit / same response imperative"
    fi
fi

# ---------------------------------------------------------------------------
# 13. Per-site co-emit reminders at each CONFIRM_<STAGE> emission point.
# ---------------------------------------------------------------------------
echo "=== 13. clarify-intent / make-outline-plan / make-detail-plan: co-emit reminders ==="
for skill_pair in \
    "$CLARIFY_INTENT_SKILL:CONFIRM_INTENT" \
    "$OUTLINE_SKILL:CONFIRM_OUTLINE" \
    "$DETAIL_SKILL:CONFIRM_DETAIL"; do
    skill_file="${skill_pair%%:*}"
    skill_name="$(basename "$(dirname "$skill_file")")"
    if require_file "$skill_file"; then
        if has "SAME response|co-emit" "$skill_file"; then
            pass "$skill_name/SKILL.md has co-emit reminder"
        else
            fail "$skill_name/SKILL.md missing co-emit reminder at CONFIRM site"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Case D: sentinel-patterns.js must NOT contain CONFIRM_PR_CREATED_RE_DQ
# ---------------------------------------------------------------------------
echo "=== Case D: sentinel-patterns.js: CONFIRM_PR_CREATED_RE_DQ absent ==="
if require_file "$SENTINEL_PATTERNS"; then
    if has_fixed "CONFIRM_PR_CREATED_RE_DQ" "$SENTINEL_PATTERNS"; then
        fail "sentinel-patterns.js still contains CONFIRM_PR_CREATED_RE_DQ"
    else
        pass "sentinel-patterns.js: CONFIRM_PR_CREATED_RE_DQ absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case E: confirm-checkpoint.js must NOT contain CONFIRM_PR_CREATED_BODY_RE
# ---------------------------------------------------------------------------
echo "=== Case E: confirm-checkpoint.js: CONFIRM_PR_CREATED_BODY_RE absent ==="
CONFIRM_CHECKPOINT="$REPO_ROOT/hooks/confirm-checkpoint.js"
if require_file "$CONFIRM_CHECKPOINT"; then
    if has_fixed "CONFIRM_PR_CREATED_BODY_RE" "$CONFIRM_CHECKPOINT"; then
        fail "confirm-checkpoint.js still contains CONFIRM_PR_CREATED_BODY_RE reference"
    else
        pass "confirm-checkpoint.js: CONFIRM_PR_CREATED_BODY_RE absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case F: state-io.js must NOT contain pr-created in CONFIRM_NEXT_STEP_HINT
# ---------------------------------------------------------------------------
echo "=== Case F: state-io.js: pr-created hint absent ==="
STATE_IO="$REPO_ROOT/hooks/lib/workflow-state/state-io.js"
if require_file "$STATE_IO"; then
    if has_fixed "pr-created" "$STATE_IO"; then
        fail "state-io.js still contains pr-created in CONFIRM_NEXT_STEP_HINT"
    else
        pass "state-io.js: pr-created absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case G: settings.json must NOT contain CONFIRM_PR_CREATED in ask list
# ---------------------------------------------------------------------------
echo "=== Case G: settings.json: CONFIRM_PR_CREATED absent from ask list ==="
SETTINGS_JSON="$REPO_ROOT/settings.json"
if require_file "$SETTINGS_JSON"; then
    if has_fixed "CONFIRM_PR_CREATED" "$SETTINGS_JSON"; then
        fail "settings.json still contains CONFIRM_PR_CREATED in ask list"
    else
        pass "settings.json: CONFIRM_PR_CREATED absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case H: stop-confirm-plan-guard.js must NOT contain CONFIRM_PR_CREATED_RE_DQ
# ---------------------------------------------------------------------------
echo "=== Case H: stop-confirm-plan-guard.js: CONFIRM_PR_CREATED_RE_DQ absent ==="
STOP_GUARD="$REPO_ROOT/hooks/stop-confirm-plan-guard.js"
if require_file "$STOP_GUARD"; then
    if has_fixed "CONFIRM_PR_CREATED_RE_DQ" "$STOP_GUARD"; then
        fail "stop-confirm-plan-guard.js still contains CONFIRM_PR_CREATED_RE_DQ"
    else
        pass "stop-confirm-plan-guard.js: CONFIRM_PR_CREATED_RE_DQ absent"
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

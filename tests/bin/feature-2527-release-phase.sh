#!/bin/bash
# tests/bin/feature-2527-release-phase.sh
# Tests: bin/workflow/lib/next-step/steps.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/delivery-path-note.js, hooks/workflow-state/effective-state/delivery-boundary.js, hooks/workflow-state/delivery-settle.js, hooks/workflow-state/evidence-resolver/release-evidence.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-gate/gh-detect.js, hooks/lib/merge-detect.js, hooks/workflow-mark/mark-step-handler.js, bin/session-close-detect-route.js, skills/merge-to-main/SKILL.md, bin/workflow/pr-state, skills/get-release-approval/scripts/preflight.sh
# Tags: scope:issue-specific, workflow, release-phase
# Issue #2527 stage 3 (release phase). Dispatcher (file-split rule): one sub-file per plan
# item under 3-12 in the sibling feature-2527-release-phase/ folder; each case runs one sub-file.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (not caught here): see each sub-file's own TL3 gap block.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
SUB="$TESTS_DIR/feature-2527-release-phase"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

run_sub() {
    local out rc p f s
    out="$(bash "$1" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    s=$(printf '%s\n' "$out" | grep -c '^SKIP:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_SKIP=$((TOTAL_SKIP + s))
    # Nonzero exit with no FAIL: lines = the child crashed before reporting (no false green).
    if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
        printf 'FAIL: %s exited with status %s but printed no FAIL: lines (likely a crash)\n' "$1" "$rc"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

case_begin "next-step release-phase verdicts" "bin/workflow/lib/next-step/steps.js"
run_sub "$SUB/next-step-release.sh"
case_end

case_begin "delivery-boundary reset predicate" "hooks/workflow-state/effective-state/delivery-boundary.js"
run_sub "$SUB/delivery-boundary.sh"
case_end

case_begin "settleMergeToMain single-append settlement" "hooks/workflow-state/delivery-settle.js"
run_sub "$SUB/delivery-settle.sh"
case_end

case_begin "commit gate release-step exemptions" "hooks/workflow-gate/commit-gate-steps.js"
run_sub "$SUB/commit-gate.sh"
case_end

case_begin "merge detection incl. glab" "hooks/lib/merge-detect.js"
run_sub "$SUB/merge-detect-glab.sh"
case_end

case_begin "release evidence resolver" "hooks/workflow-state/evidence-resolver/release-evidence.js"
run_sub "$SUB/release-evidence.sh"
case_end

case_begin "DELIVERY_PATH_MISMATCH note" "bin/workflow/lib/next-step/delivery-path-note.js"
run_sub "$SUB/delivery-path-note.sh"
case_end

case_begin "premature USER_VERIFIED guard" "hooks/workflow-gate/gh-detect.js"
run_sub "$SUB/premature-guard.sh"
case_end

case_begin "MARK_STEP evidence for release steps" "hooks/workflow-mark/mark-step-handler.js"
run_sub "$SUB/mark-step-evidence.sh"
case_end

case_begin "session-close route by recorded path" "bin/session-close-detect-route.js"
run_sub "$SUB/session-close-route.sh"
case_end

case_begin "session-close build-env argv + PR head matching" "bin/session-close-build-env.js"
run_sub "$SUB/session-close-build-env-argv.sh"
case_end

case_begin "skill responsibility moves (static)" "skills/merge-to-main/SKILL.md"
run_sub "$SUB/skill-static.sh"
case_end

case_begin "pr-state CLI per forge" "bin/workflow/pr-state"
run_sub "$SUB/pr-state-cli.sh"
case_end

case_begin "get-release-approval preflight execution" "skills/get-release-approval/scripts/preflight.sh"
run_sub "$SUB/preflight-exec.sh"
case_end

case_begin "web-merge channel: next-step wait + evidence" "bin/workflow/lib/next-step/release-wait.js"
run_sub "$SUB/web-merge-channel.sh"
case_end

case_begin "web-merge poller (wait-web-merge.sh)" "skills/get-release-approval/scripts/wait-web-merge.sh"
run_sub "$SUB/web-merge-poller.sh"
case_end

case_begin "step rename deliver -> merge_to_main" "hooks/workflow-state/step-table.js"
run_sub "$SUB/step-rename.sh"
case_end

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed, $TOTAL_SKIP skipped"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"
exit $TOTAL_FAIL

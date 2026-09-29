#!/bin/bash
# tests/hooks/feature-833-review-tests-gate/section-e.sh
# Tests: hooks/workflow-gate/review-tests-checker.js
# Tags: workflow, gate, hook, review-tests, mark-step, scope:issue-specific
#
# Section E: manual MARK_STEP review_tests is rejected (fingerprint-only path).
# Sourced by tests/hooks/feature-833-review-tests-gate.sh; inherits its helpers.

echo ""
echo "=== Section E: Manual MARK_STEP rejection ==="

# E7: the generic WORKFLOW_MARK_STEP_review_tests_complete sentinel must be rejected;
# review_tests transitions only via REVIEW_TESTS_COMPLETE / _WARNINGS (fingerprint).
SID_E7="e7-$$"
PAIR_E7="$(setup_linked_worktree "secE-wt7")"
WT_E7="${PAIR_E7#*|}"
stage_test_file "$WT_E7" "tests/example.sh" "echo test E7"
write_state "$SID_E7" "$(state_json_custom "$SID_E7" "feature/secE-wt7" review_tests pending)"
SENTINEL_E7='echo "<<WORKFLOW_MARK_STEP_review_tests_complete>>"'
run_mark "$WT_E7" "$(build_mark_json "$SENTINEL_E7" "$SID_E7" 0 "$WT_E7")" >/dev/null
STATUS_E7="$(read_state_step "$SID_E7" review_tests)"
if [ "$STATUS_E7" = "pending" ]; then
    pass "E7. generic MARK_STEP review_tests_complete is rejected (still pending)"
else
    fail "E7. expected pending (manual mark rejected), got status=$STATUS_E7"
fi

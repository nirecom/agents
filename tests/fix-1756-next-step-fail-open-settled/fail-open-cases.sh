#!/usr/bin/env bash
# filename: tests/fix-1756-next-step-fail-open-settled/fail-open-cases.sh
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, next-step, fail-open, settled-status, TL2, scope:common
#
# Case file — sourced by tests/fix-1756-next-step-fail-open-settled.sh, which
# owns every helper and fixture fragment used here. Do not run standalone.
#
# F1-F3, F5: RED behavioral cases for #1756 (settled write_tests must terminate
# the workflow). F4, F6: guards that pass before AND after the fix.

# ---------------------------------------------------------------------------
# F1 (RED): outline recorded-verdict skipped + every other step complete
# (write_tests: complete) → the workflow is finished, so ACTION=done.
# ---------------------------------------------------------------------------
F1_SID="$(new_sid f1)"
write_state "$F1_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_COMPLETE}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F1_OUT="$(run_next_step --session "$F1_SID")"
eval "$F1_OUT" 2>/dev/null || true
check_eq "F1: outline recorded-verdict skip + write_tests complete → ACTION=done" \
    "done" "${ACTION:-}"
check_eq "F1: REASON=workflow-complete" "workflow-complete" "${REASON:-}"
check_eq "F1: NEXT_SKILL is empty" "" "${NEXT_SKILL:-}"
check_eq "F1: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F1_SID" "outline" "status")"
check_eq "F1: on-disk write_tests.status still literally complete (no rewrite)" \
    "complete" "$(raw_step_field "$F1_SID" "write_tests" "status")"

# ---------------------------------------------------------------------------
# F2 (RED): the symmetric sibling — detail is the recorded-verdict skip and
# outline is complete. Same class member, same loop (CPR-5).
# ---------------------------------------------------------------------------
F2_SID="$(new_sid f2)"
write_state "$F2_SID" "{$HEAD_COMPLETE,\"outline\":{\"status\":\"complete\"},$RV_DETAIL,$TAIL_COMPLETE}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F2_OUT="$(run_next_step --session "$F2_SID")"
eval "$F2_OUT" 2>/dev/null || true
check_eq "F2: detail recorded-verdict skip + write_tests complete → ACTION=done" \
    "done" "${ACTION:-}"
check_eq "F2: on-disk detail.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F2_SID" "detail" "status")"

# ---------------------------------------------------------------------------
# F3 (RED): BOTH gated steps recorded-verdict skipped — confirms the loop walks
# every APPROVAL_GATED_STEPS member without re-invoking write-tests.
# ---------------------------------------------------------------------------
F3_SID="$(new_sid f3)"
write_state "$F3_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,$RV_DETAIL,$TAIL_COMPLETE}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F3_OUT="$(run_next_step --session "$F3_SID")"
eval "$F3_OUT" 2>/dev/null || true
check_eq "F3: outline+detail recorded-verdict skipped → ACTION=done" "done" "${ACTION:-}"
check_not_contains "F3: does not route back to write-tests" "write-tests" "$F3_OUT"
check_eq "F3: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F3_SID" "outline" "status")"
check_eq "F3: on-disk detail.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F3_SID" "detail" "status")"

# ---------------------------------------------------------------------------
# F4 (regression guard): the already-correct path — write_tests explicitly
# skipped. Must hold before AND after the fix.
# ---------------------------------------------------------------------------
F4_SID="$(new_sid f4)"
write_state "$F4_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_WTS_SKIPPED}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F4_OUT="$(run_next_step --session "$F4_SID")"
eval "$F4_OUT" 2>/dev/null || true
check_eq "F4: outline skipped + write_tests skipped → ACTION=done" "done" "${ACTION:-}"
check_eq "F4: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F4_SID" "outline" "status")"
check_eq "F4: on-disk write_tests.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F4_SID" "write_tests" "status")"

# ---------------------------------------------------------------------------
# F5 (RED): a legacy speculative skip (skip_reason="speculative", no recorded
# skip_verdict) reaches the same terminal branch. Settled write_tests must end
# the workflow there too — same semantics as G4, pinned independently.
# ---------------------------------------------------------------------------
F5_SID="$(new_sid f5)"
write_state "$F5_SID" "{$HEAD_COMPLETE,$SPEC_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_COMPLETE}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F5_OUT="$(run_next_step --session "$F5_SID")"
eval "$F5_OUT" 2>/dev/null || true
check_eq "F5: legacy speculative outline skip + write_tests complete → ACTION=done" \
    "done" "${ACTION:-}"
check_eq "F5: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F5_SID" "outline" "status")"

# ---------------------------------------------------------------------------
# F6 (mutation probe — passes before AND after the fix): F1's gated-step fixture
# with write_tests `in_progress`. This pins the NEGATIVE branch of the settled
# predicate: an implementation written as `status !== "pending"` would treat an
# in-flight write_tests as settled, walk past it, and route to review-tests (or,
# with a settled tail, to done). Only a membership test over ["complete","skipped"]
# keeps write_tests as the current step here, so this case is what stops that
# mis-implementation from passing the suite.
#
# Fixture deviation (deliberate): the steps after write_tests stay pending — see
# TAIL_WTS_IN_PROGRESS in the dispatcher. A completed later step would trip the
# inconsistency scan / review_tests-ordering recovery and emit ACTION=abort
# before any settled-status check ran, proving nothing about the predicate.
# ---------------------------------------------------------------------------
F6_SID="$(new_sid f6)"
write_state "$F6_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_WTS_IN_PROGRESS}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
F6_OUT="$(run_next_step --session "$F6_SID")"
eval "$F6_OUT" 2>/dev/null || true
check_eq "F6: write_tests in_progress is NOT settled → ACTION=invoke" "invoke" "${ACTION:-}"
check_eq "F6: write_tests in_progress → NEXT_SKILL=write-tests" "write-tests" "${NEXT_SKILL:-}"
check_eq "F6: on-disk write_tests.status still literally in_progress (no rewrite)" \
    "in_progress" "$(raw_step_field "$F6_SID" "write_tests" "status")"
check_eq "F6: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$F6_SID" "outline" "status")"

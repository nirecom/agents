# shellcheck shell=bash
# Tests: bin/workflow/lib/next-step/verdict.js, bin/workflow/next-step, hooks/workflow-state/state-io/migrations/v2-to-v3.js
# Tags: TL2, workflow, write-code, next-step, legacy-state, migration, recovery-hint, scope:issue-specific, pwsh-not-required
#
# Case group C (TL2): the two states that LOOK alike on disk — "write_code is not
# complete while run_tests is" — and must be judged differently.
#
# 1. MIGRATION ARTIFACT (C1-C3): a session that started before write_code existed
#    has no write_code record at all. Since the v3 schema version
#    (state-io/migrations/v2-to-v3.js) that file is raised on read and write_code
#    is backfilled complete, so next-step just carries on. Aborting here would
#    stop a session that did nothing wrong.
# 2. GENUINE INCONSISTENCY (C4-C7): write_code was RECORDED pending — a manual
#    --reset or a RESET_FROM — while run_tests stands complete. Nothing can
#    reconstruct that, so verdict.js still aborts, with the scoped MARK_STEP
#    recovery rather than the destructive "Re-run /workflow-init" reset.
#
# The two fixtures differ ONLY in whether the write_code entry exists, which is
# what makes the difference in verdict attributable to the migration.

run_legacy_state_tests() {
  # step_field returns the JSON-encoded field, so a string status arrives quoted.
  local out ACTION NEXT_SKILL NEXT_HINT REASON wc_status

  # ── 1. migration artifact: write_code key absent ──────────────────────────
  # All other steps are written explicitly so applyLegacyV1ReadDefaults cannot
  # synthesize a status and change which step is current.
  build_state c-legacy pending \
    "workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete;write_code=absent;run_tests=complete"

  wc_status="$(step_field c-legacy write_code status)"
  check "C1: the absent write_code entry reads back as complete (v2->v3 backfill)" \
    '"complete"' "$wc_status"

  ACTION=""; NEXT_SKILL=""; NEXT_HINT=""; REASON=""
  out="$(run_next_step --session c-legacy 2>/dev/null || true)"
  eval "$out" 2>/dev/null || true

  check "C2: the legacy session keeps advancing instead of aborting" "invoke" "${ACTION:-}"
  # run_tests is complete in the fixture, so the next unsettled step is the one
  # that follows it in VALID_STEPS: review_security.
  check "C3: it advances to the step after run_tests" "review-code-security" "${NEXT_SKILL:-}"

  # ── 2. genuine inconsistency: write_code RECORDED pending ─────────────────
  build_state c-inconsistent pending \
    "workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete;write_code=pending;run_tests=complete"
  stamp_step_at c-inconsistent write_code >/dev/null

  wc_status="$(step_field c-inconsistent write_code status)"
  check "C4: a recorded pending write_code survives the migration untouched" \
    '"pending"' "$wc_status"

  ACTION=""; NEXT_SKILL=""; NEXT_HINT=""; REASON=""
  out="$(run_next_step --session c-inconsistent 2>/dev/null || true)"
  eval "$out" 2>/dev/null || true

  check "C5: a recorded pending write_code under a complete run_tests still aborts" \
    "abort" "${ACTION:-}"
  check_contains "C6: REASON names write_code as the pending step" "write_code" "${REASON:-}"
  check_contains "C7: hint offers the scoped MARK_STEP recovery" \
    "WORKFLOW_MARK_STEP_write_code_complete" "${NEXT_HINT:-}"
  check_not_contains "C8: hint does NOT order a destructive /workflow-init reset" \
    "Re-run /workflow-init" "${NEXT_HINT:-}"
}

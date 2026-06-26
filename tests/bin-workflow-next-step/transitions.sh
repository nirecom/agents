# shellcheck shell=bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, scope:common
#
# Case group: state-transition resolution (cases 1–13b).
# Sourced by bin-workflow-next-step.sh; relies on helpers/fixtures from common.sh.

run_transitions_tests() {
  local OUT ACTION NEXT_SKILL NEXT_HINT REASON

  # ---- Case 1: no-state-file ------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  OUT="$(run_oracle --session "nonexistent-$$" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "1: no-state-file ACTION=invoke" "invoke" "${ACTION:-}"
  check "1: no-state-file NEXT_SKILL=workflow-init" "workflow-init" "${NEXT_SKILL:-}"

  # ---- Case 2: all-pending --------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case2" "$JSON_ALL_PENDING"
  OUT="$(run_oracle --session "case2" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "2: all-pending ACTION=invoke" "invoke" "${ACTION:-}"
  check "2: all-pending NEXT_SKILL=workflow-init" "workflow-init" "${NEXT_SKILL:-}"

  # ---- Case 3: workflow_init-complete --------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case3" "$JSON_WFINIT_COMPLETE"
  OUT="$(run_oracle --session "case3" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "3: workflow_init-complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "3: workflow_init-complete NEXT_SKILL=clarify-intent" "clarify-intent" "${NEXT_SKILL:-}"

  # ---- Case 4: clarify_intent-complete -------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case4" "$JSON_CLARIFY_COMPLETE"
  OUT="$(run_oracle --session "case4" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "4: clarify_intent-complete ACTION=invoke" "invoke" "${ACTION:-}"
  check "4: clarify_intent-complete NEXT_SKILL=survey-code" "survey-code" "${NEXT_SKILL:-}"

  # ---- Case 5: research-skipped --------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case5" "$JSON_RESEARCH_SKIPPED"
  OUT="$(run_oracle --session "case5" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "5: research-skipped ACTION=invoke" "invoke" "${ACTION:-}"
  check "5: research-skipped NEXT_SKILL=make-outline-plan" "make-outline-plan" "${NEXT_SKILL:-}"

  # ---- Case 6: write_tests + review_tests skipped --------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case6" "$JSON_TESTS_SKIPPED"
  OUT="$(run_oracle --session "case6" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "6: tests-skipped ACTION=invoke" "invoke" "${ACTION:-}"
  check "6: tests-skipped NEXT_SKILL=run-tests" "run-tests" "${NEXT_SKILL:-}"

  # ---- Case 7: in_progress step --------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case7" "$JSON_WRITE_TESTS_IN_PROGRESS"
  OUT="$(run_oracle --session "case7" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "7: in_progress ACTION=invoke" "invoke" "${ACTION:-}"
  check "7: in_progress NEXT_SKILL=write-tests" "write-tests" "${NEXT_SKILL:-}"

  # ---- Case 8: all-complete -------------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case8" "$JSON_ALL_COMPLETE"
  OUT="$(run_oracle --session "case8" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "8: all-complete ACTION=done" "done" "${ACTION:-}"
  check "8: all-complete NEXT_SKILL empty" "" "${NEXT_SKILL:-}"

  # ---- Case 9: mixed-terminal ----------------------------------------------
  ACTION=""; NEXT_SKILL=""
  write_state "case9" "$JSON_MIXED_TERMINAL"
  OUT="$(run_oracle --session "case9" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "9: mixed-terminal ACTION=done" "done" "${ACTION:-}"
  check "9: mixed-terminal NEXT_SKILL empty" "" "${NEXT_SKILL:-}"

  # ---- Case 10: closes_issues-blocked --------------------------------------
  ACTION=""; REASON=""
  write_state "case10" "$JSON_BLOCKED"
  OUT="$(run_oracle --session "case10" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "10: closes_issues-blocked ACTION=blocked" "blocked" "${ACTION:-}"
  check_contains "10: closes_issues-blocked REASON marker" "closes_issues-empty" "${REASON:-}"

  # ---- Case 11: closes_issues-not-blocked (past clarify_intent) ------------
  ACTION=""; NEXT_SKILL=""
  write_state "case11" "$JSON_NOT_BLOCKED"
  OUT="$(run_oracle --session "case11" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "11: closes_issues-not-blocked ACTION=invoke" "invoke" "${ACTION:-}"

  # ---- Case 12: corrupt-state ----------------------------------------------
  ACTION=""; REASON=""
  write_state "case12" "$JSON_CORRUPT"
  OUT="$(run_oracle --session "case12" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "12: corrupt-state ACTION=abort" "abort" "${ACTION:-}"
  check_contains "12: corrupt-state REASON marker" "corrupt-state:" "${REASON:-}"

  # ---- Case 13: inconsistent-state -----------------------------------------
  ACTION=""; REASON=""
  write_state "case13" "$JSON_INCONSISTENT"
  OUT="$(run_oracle --session "case13" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "13: inconsistent-state ACTION=abort" "abort" "${ACTION:-}"
  check_contains "13: inconsistent-state REASON marker" "inconsistent:" "${REASON:-}"

  # ---- Case 13b: cross-task contamination (#1068) --------------------------
  # pre_final_report_gate=complete from a prior workflow run; clarify_intent=pending now.
  # Oracle must abort with a non-empty NEXT_HINT (recovery hint).
  ACTION=""; REASON=""; NEXT_HINT=""
  write_state "case13b" "$JSON_CROSS_TASK_CONTAM"
  OUT="$(run_oracle --session "case13b" 2>/dev/null || true)"
  eval "$OUT" 2>/dev/null || true
  check "13b: cross-task-contam ACTION=abort" "abort" "${ACTION:-}"
  check_contains "13b: cross-task-contam REASON marker" "inconsistent:" "${REASON:-}"
  if [ -n "${NEXT_HINT:-}" ]; then
    echo "PASS: 13b: cross-task-contam NEXT_HINT non-empty"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 13b: cross-task-contam NEXT_HINT should be non-empty (got empty)"
    FAIL=$((FAIL + 1))
  fi
}

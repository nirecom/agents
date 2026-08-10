# shellcheck shell=bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/list.js, hooks/workflow-mark/reset-handler.js
# Tags: TL2, workflow, write-code, next-step, reset-sentinel, scope:issue-specific, pwsh-not-required
#
# Case group B (TL2): the two consumers that walk VALID_STEPS by array position
# and must follow the insertion automatically — the real `next-step --list`
# renderer and the real RESET_FROM sentinel handler. Both run as subprocesses
# against a fixture state file, so a table that lists the step but a walker that
# does not reach it still fails here.

run_list_reset_tests() {
  local list_out line_count mark_out

  # ---- B1/B2: --list renders 16 rows including write_code -------------------
  list_out="$(run_next_step --list 2>/dev/null || true)"
  line_count="$(printf '%s\n' "$list_out" | grep -c . || true)"
  check "B1: --list emits 16 rows" "16" "$line_count"
  check_contains "B2: --list names write_code" "write_code" "$list_out"

  # ---- B3: write_code renders between review_tests and run_tests -----------
  # Row order is the vocabulary order; asserting the neighbours here catches an
  # insertion made at the wrong index that B1/B2 alone would accept.
  local order
  order="$(printf '%s\n' "$list_out" | grep -oE 'review_tests|write_code|run_tests' | tr '\n' ' ')"
  check "B3: --list order is review_tests write_code run_tests" \
    "review_tests write_code run_tests " "$order"

  # ---- B4..B8: WORKFLOW_RESET_FROM_write_code is accepted -------------------
  # Reset semantics (reset-handler.js): every step BEFORE the target is forced
  # complete, the target and everything after it return to pending.
  build_state b-reset pending
  mark_out="$(run_mark_hook b-reset 'echo "<<WORKFLOW_RESET_FROM_write_code: verify write_code is a resettable step>>"')"

  check_not_contains "B4: reset sentinel is not rejected as an unknown step" \
    "unknown step" "$mark_out"
  check "B5: reset forces write_tests (before target) complete" \
    '"complete"' "$(step_field b-reset write_tests status)"
  check "B6: reset forces review_tests (immediately before target) complete" \
    '"complete"' "$(step_field b-reset review_tests status)"
  check "B7: reset leaves write_code (the target) pending" \
    '"pending"' "$(step_field b-reset write_code status)"
  check "B8: reset leaves run_tests (after target) pending" \
    '"pending"' "$(step_field b-reset run_tests status)"
}

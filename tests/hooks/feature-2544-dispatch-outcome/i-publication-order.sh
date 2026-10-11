# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/i-publication-order.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-state/dispatch-settlement.js
# Tags: workflow, run-tests, worker-dispatch, publication-order, race, hook, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# Two dispatches overlap: 11 and 12 are both claimed, and 11 finishes first with a
# pass. Only the latest dispatch settles run_tests, so 11's pass must not complete
# it while 12 is still running, and 12's later failure is what gets recorded.

f2544_i_latest_dispatch_decides() {
  local sid="f2544-i-order" first="$F2544_T-10" b="$F2544_T-11" a="$F2544_T-12"

  f2544_ready "$sid"
  f2544_dispatched "$sid" "$first"
  f2544_pass_outcome "$sid" "$first"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "I/order: precondition — sequence 10 is ingested" "$sid" "$first" || return 0
  f2544_eq "I/order: precondition — complete from sequence 10" "$(f2544_status "$sid")" "complete"

  f2544_dispatched "$sid" "$b"
  f2544_dispatched "$sid" "$a"
  f2544_pass_outcome "$sid" "$b"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "I/order: the earlier dispatch's pass does not complete while the later one runs" "$(f2544_status "$sid")" "pending"
  f2544_eq "I/order: the later dispatch is the unsettled one" "$(f2544_probe unsettled "$sid")" "$a"
  f2544_eq "I/order: the earlier dispatch's outcome is not ingested" "$(f2544_probe exists "$sid" "$b.ingested")" "no"
  f2544_eq "I/order: outcome_source no longer counts — 10's record was demoted" "$(f2544_field "$sid" run_outcome)" "absent"

  f2544_fail_outcome "$sid" "$a"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "I/order: the later failing outcome is ingested" "$sid" "$a" || return 0
  f2544_eq "I/order: run_tests is pending on the later failure" "$(f2544_status "$sid")" "pending"
  f2544_eq "I/order: the later failing_tests are recorded" "$(f2544_field "$sid" failing_tests)" "[\"$F2544_FAILING_REL\"]"
  f2544_eq "I/order: outcome_source names the later dispatch" "$(f2544_source_stem "$sid")" "$a"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "I/order: the earlier pass is still never ingested" "$(f2544_probe exists "$sid" "$b.ingested")" "no"
}

case_begin "latest-dispatch-alone-settles-run-tests" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_i_latest_dispatch_decides
case_end

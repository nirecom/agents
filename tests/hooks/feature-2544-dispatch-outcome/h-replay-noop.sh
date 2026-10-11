# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/h-replay-noop.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests/record-run.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, idempotency, replay, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# The hook writes state first and the .ingested marker second. A stop in between
# leaves the marker missing; the next call must see outcome_source already naming
# the same stem and outcome bytes, rebuild the marker and write no state, or it
# would advance updated_seq twice and wipe whatever was recorded in between.

# f2544_h_ingest <label> <sid> <pass|fail> — precondition: one ingested outcome.
f2544_h_ingest() {
  local sid="$2" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  if [[ "$3" == "pass" ]]; then f2544_pass_outcome "$sid" "$stem"; else f2544_fail_outcome "$sid" "$stem"; fi
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "H/$1: precondition — the outcome was ingested" "$sid" "$stem"
}

# f2544_h_replay <label> <sid> — drop the marker, call the hook three times, expect no write.
f2544_h_replay() {
  local label="$1" sid="$2" stem="$F2544_T-1" events seq
  events="$(f2544_events "$sid")"
  seq="$(f2544_seq "$sid")"
  f2544_probe rm "$sid" "$stem.ingested"
  f2544_eq "H/$label: control — the marker is gone before the replay" "$(f2544_probe exists "$sid" "$stem.ingested")" "no"
  f2544_hook_times 3 "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "H/$label: three hook calls append no event" "$(f2544_events "$sid")" "$events"
  f2544_eq "H/$label: run_tests updated_seq does not move" "$(f2544_seq "$sid")" "$seq"
  f2544_eq "H/$label: the ingested marker is recreated" "$(f2544_probe exists "$sid" "$stem.ingested")" "yes"
}

f2544_h_plain_replay() {
  local sid="f2544-h-plain"
  f2544_h_ingest "plain" "$sid" pass || return 0
  f2544_h_replay "plain" "$sid"
  f2544_eq "H/plain: still complete" "$(f2544_status "$sid")" "complete"
  f2544_eq "H/plain: outcome_source is unchanged" "$(f2544_source_stem "$sid")" "$F2544_T-1"
}

f2544_h_fail_replay() {
  local sid="f2544-h-fail"
  f2544_h_ingest "fail" "$sid" fail || return 0
  f2544_h_replay "fail" "$sid"
  f2544_eq "H/fail: still pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "H/fail: the failing list is unchanged" "$(f2544_field "$sid" failing_tests)" "[\"$F2544_FAILING_REL\"]"
}

f2544_h_baseline_record_between() {
  local sid="f2544-h-baseline" stem="$F2544_T-1" seq verdict
  f2544_h_ingest "baseline" "$sid" fail || return 0
  seq="$(f2544_probe baseline-seq "$sid")"
  f2544_probe rm "$sid" "$stem.ingested"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  verdict="$(f2544_probe baseline-record "$sid" "$seq" "$F2544_FAILING_REL")"
  f2544_eq "H/baseline: the comparison record is not refused for a seq mismatch" "$verdict" "0:absent"
  f2544_eq "H/baseline: precondition — the comparison completed run_tests" "$(f2544_status "$sid")" "complete"
  f2544_h_replay "baseline" "$sid"
  f2544_eq "H/baseline: the comparison's complete survives" "$(f2544_status "$sid")" "complete"
  f2544_eq "H/baseline: its basis survives" "$(f2544_field "$sid" completion_basis)" "baseline-preexisting"
  f2544_ne "H/baseline: the classification record survives" "$(f2544_field "$sid" baseline_classification)" "absent"
}

case_begin "replay-after-lost-marker-writes-nothing" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_h_plain_replay
case_end

case_begin "replay-of-a-failing-outcome-writes-nothing" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_h_fail_replay
case_end

case_begin "replay-keeps-a-merge-base-comparison-record" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_h_baseline_record_between
case_end

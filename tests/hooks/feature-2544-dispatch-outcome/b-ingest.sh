# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/b-ingest.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/failing-list.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, ingest, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# The hook ingests an outcome file on whatever Bash call comes next; the command
# string of that call plays no part, so every case here drives an unrelated command.

f2544_b_pass_completes() {
  local sid="f2544-b-pass" stem="$F2544_T-1" events
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "ls -la"
  f2544_eq "B/pass: run_tests is complete" "$(f2544_status "$sid")" "complete"
  f2544_eq "B/pass: run_outcome is pass" "$(f2544_field "$sid" run_outcome)" "pass"
  f2544_ingested "B/pass: ingested marker written" "$sid" "$stem" || return 0
  f2544_eq "B/pass: outcome_source names the stem" "$(f2544_source_stem "$sid")" "$stem"
  f2544_eq "B/pass: outcome_source carries the payload digest" \
    "$(f2544_probe path "$sid" run_tests "$F2544_KEY_SOURCE" payload_sha256)" \
    "$(f2544_probe sha "$sid" "$stem.json")"
  f2544_eq "B/pass: outcome_source carries the outcome file digest" \
    "$(f2544_probe path "$sid" run_tests "$F2544_KEY_SOURCE" outcome_sha256)" "$(f2544_probe sha "$sid" "$stem.outcome.json")"
  f2544_eq "B/pass: the dispatch is no longer unsettled" "$(f2544_field "$sid" "$F2544_KEY_UNSETTLED")" "absent"
  events="$(f2544_events "$sid")"
  f2544_hook_times 2 "$sid" "ls -la"
  f2544_eq "B/pass: later hook calls append nothing" "$(f2544_events "$sid")" "$events"
  f2544_eq "B/pass: still complete after later hook calls" "$(f2544_status "$sid")" "complete"
}

f2544_b_fail_records_failing_tests() {
  local sid="f2544-b-fail" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  f2544_dispatched "$sid" "$stem"
  f2544_fail_outcome "$sid" "$stem"
  f2544_hook "$sid" "ls -la"
  f2544_ingested "B/fail: ingested marker written" "$sid" "$stem" || return 0
  f2544_eq "B/fail: run_tests is pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "B/fail: run_outcome is fail" "$(f2544_field "$sid" run_outcome)" "fail"
  f2544_eq "B/fail: failing_tests is the outcome's list" "$(f2544_field "$sid" failing_tests)" "[\"$F2544_FAILING_REL\"]"
  f2544_eq "B/fail: outcome_source names the failing dispatch" "$(f2544_source_stem "$sid")" "$stem"
}

f2544_b_timeout_is_not_a_pass() {
  local sid="f2544-b-timeout" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" timeout 3 0 '[]' '{"exit_code":-1,"worker_result":{"run_contract":null}}'
  f2544_hook "$sid" "ls -la"
  f2544_ingested "B/timeout: ingested marker written" "$sid" "$stem" || return 0
  f2544_eq "B/timeout: run_tests is pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "B/timeout: run_outcome is timeout" "$(f2544_field "$sid" run_outcome)" "timeout"
}

f2544_b_pass_status_with_failing_contract() {
  local sid="f2544-b-mixed" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" pass 2 1 "[\"$F2544_FAILING_REL\"]"
  f2544_hook "$sid" "ls -la"
  f2544_ne "B/mixed: a pass word over a failing contract does not complete" "$(f2544_status "$sid")" "complete"
  f2544_eq "B/mixed: the failing contract decides run_outcome" "$(f2544_field "$sid" run_outcome)" "fail"
}

# f2544_b_no_test_ran <tag> <run-contract-json>: a pass word over a run that ran no test.
# The closing control re-runs the same session with a contract in which tests ran,
# so the refusals above it cannot pass merely because nothing is ingested at all.
f2544_b_no_test_ran() {
  local tag="$1" sid="f2544-b-$1" stem="$F2544_T-1" next="$F2544_T-2"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" pass 0 0 '[]' "{\"worker_result\":{\"run_contract\":$2}}"
  f2544_eq "B/$tag: control — the outcome file is in place" "$(f2544_probe exists "$sid" "$stem.outcome.json")" "yes"
  f2544_hook_times 2 "$sid" "$F2544_UNRELATED_CMD"
  f2544_ne "B/$tag: a pass word with no test run does not complete" "$(f2544_status "$sid")" "complete"
  f2544_ne "B/$tag: run_outcome is not pass" "$(f2544_field "$sid" run_outcome)" "pass"
  f2544_eq "B/$tag: the outcome is still consumed" "$(f2544_probe exists "$sid" "$stem.ingested")" "yes"

  f2544_dispatched "$sid" "$next"
  f2544_pass_outcome "$sid" "$next"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "B/$tag: control — a later run that ran tests completes the same session" "$(f2544_status "$sid")" "complete"
  f2544_eq "B/$tag: control — and outcome_source names that run" "$(f2544_source_stem "$sid")" "$next"
}

f2544_b_write_tests_not_settled() {
  local sid="f2544-b-nowt" stem="$F2544_T-1"
  f2544_probe seed "$sid" workflow_init complete
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "ls -la"
  f2544_eq "B/write_tests pending: control — write_tests really is pending" "$(f2544_probe field "$sid" write_tests status)" "pending"
  f2544_ne "B/write_tests pending: a passing outcome does not complete" "$(f2544_status "$sid")" "complete"
  f2544_ingested "B/write_tests pending: the outcome is consumed, a re-run is needed" "$sid" "$stem" || return 0
  f2544_probe seed "$sid" write_tests complete
  f2544_hook "$sid" "ls -la"
  f2544_ne "B/write_tests pending: the consumed outcome is not replayed later" "$(f2544_status "$sid")" "complete"
}

f2544_b_write_tests_skipped() {
  local sid="f2544-b-wtskip" stem="$F2544_T-1"
  f2544_probe seed "$sid" write_tests skipped
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "ls -la"
  f2544_eq "B/write_tests skipped: control — the seed took" "$(f2544_probe field "$sid" write_tests status)" "skipped"
  f2544_eq "B/write_tests skipped: a passing outcome completes" "$(f2544_status "$sid")" "complete"
}

f2544_b_late_older_outcome() {
  local sid="f2544-b-late" old="$F2544_T-1" new="$F2544_T-2"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$old"
  f2544_dispatched "$sid" "$new"
  f2544_pass_outcome "$sid" "$new"
  f2544_hook "$sid" "ls -la"
  f2544_ingested "B/late: the newer outcome is ingested first" "$sid" "$new" || return 0
  f2544_eq "B/late: precondition — complete from the newer run" "$(f2544_status "$sid")" "complete"
  f2544_fail_outcome "$sid" "$old"
  f2544_hook_times 2 "$sid" "ls -la"
  f2544_eq "B/late: the older outcome does not demote the newer result" "$(f2544_status "$sid")" "complete"
  f2544_eq "B/late: the older failing list is not recorded" "$(f2544_field "$sid" failing_tests)" "absent"
  f2544_eq "B/late: outcome_source still names the newer dispatch" "$(f2544_source_stem "$sid")" "$new"
  f2544_eq "B/late: the older outcome is never ingested" "$(f2544_probe exists "$sid" "$old.ingested")" "no"
}

f2544_b_unrelated_command() {
  local sid="f2544-b-unrelated" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_eq "B/unrelated: control — the command is not a test command" \
    "$(f2544_probe call hooks/workflow-run-tests/exec-model.js isTestCommand "[\"$F2544_UNRELATED_CMD\"]")" "false"
  f2544_eq "B/unrelated: control — pending before any hook call" "$(f2544_status "$sid")" "pending"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD" 1
  f2544_eq "B/unrelated: the hook exits 0" "$F2544_HOOK_RC" "0"
  f2544_eq "B/unrelated: ingested on a call that ran no test, whatever its exit code" "$(f2544_status "$sid")" "complete"
}

f2544_b_other_session_untouched() {
  local sid="f2544-b-owner" other="f2544-b-bystander" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_ready "$other"
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$other" "ls -la"
  f2544_eq "B/session scope: a hook call of another session ingests nothing" "$(f2544_probe exists "$sid" "$stem.ingested")" "no"
  f2544_eq "B/session scope: the other session stays pending" "$(f2544_status "$other")" "pending"
}

case_begin "passing-outcome-completes-with-outcome-source" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_pass_completes
case_end

case_begin "failing-outcome-leaves-pending-with-failing-tests" "hooks/workflow-run-tests/record-run.js"
f2544_b_fail_records_failing_tests
case_end

case_begin "timeout-outcome-is-recorded-as-not-passed" "hooks/workflow-run-tests/record-run.js"
f2544_b_timeout_is_not_a_pass
case_end

case_begin "pass-status-over-failing-contract-does-not-complete" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_pass_status_with_failing_contract
case_end

case_begin "pass-status-with-zero-executed-does-not-complete" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_no_test_ran "zero-executed" '{"pass":0,"fail":0,"skip":0,"executed":0}'
case_end

case_begin "pass-status-with-every-test-skipped-does-not-complete" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_no_test_ran "all-skipped" '{"pass":0,"fail":0,"skip":4,"executed":4}'
case_end

case_begin "passing-outcome-needs-write-tests-settled" "hooks/workflow-run-tests/record-run.js"
f2544_b_write_tests_not_settled
case_end

case_begin "passing-outcome-completes-when-write-tests-skipped" "hooks/workflow-run-tests/record-run.js"
f2544_b_write_tests_skipped
case_end

case_begin "late-older-outcome-does-not-overwrite-newer" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_late_older_outcome
case_end

case_begin "ingest-on-unrelated-command" "hooks/workflow-run-tests.js"
f2544_b_unrelated_command
case_end

case_begin "ingest-is-scoped-to-the-hook-session" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_b_other_session_untouched
case_end

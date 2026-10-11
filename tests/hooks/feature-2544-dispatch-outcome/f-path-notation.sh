# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/f-path-notation.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/dispatch-outcome.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, regression, windows-path, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# #2486 regression: a payload path written double-quoted with backslash separators was
# not matched by the hook, so the dispatch result was never recorded. Recording must
# not depend on how the command spells the path, nor on the command being recognised.

# f2544_f_cmd <sid> <stem> — the dispatch command in the notation #2486 tripped on.
f2544_f_cmd() {
  local win="$WORKFLOW_STATE_DIR/$1.control/$2.json" root="$F2544_ROOT_N"
  win="${win//\//\\}"
  root="${root//\//\\}"
  printf 'node bin/worker-dispatch.js test-runner "%s" "%s"' "$root" "$win"
}

# f2544_f_wrapped <sid> <stem> — the same dispatch in a body form the hook never
# treats as a test command.
f2544_f_wrapped() {
  local inner
  inner="$(f2544_f_cmd "$1" "$2")"
  printf 'bash -c "%s"' "${inner//\"/\\\"}"
}

# f2544_f_foreground <label> <sid> <command> <stdout>
f2544_f_foreground() {
  local label="$1" sid="$2" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "$3" 0 "$4" "$F2544_ROOT_N"
  f2544_eq "F/$label: recorded complete through the outcome file" "$(f2544_status "$sid")" "complete"
  f2544_eq "F/$label: outcome_source names the dispatch" "$(f2544_source_stem "$sid")" "$stem"
  f2544_eq "F/$label: the outcome is marked ingested" "$(f2544_probe exists "$sid" "$stem.ingested")" "yes"
}

# f2544_f_background <label> <sid> <command>
f2544_f_background() {
  local label="$1" sid="$2" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete '{"run_outcome":"pass"}'
  f2544_dispatched "$sid" "$stem"
  f2544_hook "$sid" "$3" 0 "" "$F2544_ROOT_N"
  f2544_eq "F/$label: no earlier complete survives before the outcome arrives" "$(f2544_status "$sid")" "pending"
  f2544_eq "F/$label: the earlier run_outcome is cleared with it" "$(f2544_field "$sid" run_outcome)" "absent"
  f2544_eq "F/$label: the dispatch is unsettled meanwhile" "$(f2544_probe unsettled "$sid")" "$stem"
  f2544_fail_outcome "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "F/$label: the outcome is ingested on a later call" "$sid" "$stem" || return 0
  f2544_eq "F/$label: the failing result of the background run is recorded" "$(f2544_field "$sid" failing_tests)" "[\"$F2544_FAILING_REL\"]"
  f2544_eq "F/$label: and run_tests stays pending" "$(f2544_status "$sid")" "pending"
}

f2544_f_quoted_backslash_foreground() {
  local sid stem="$F2544_T-1"
  sid="f2544-f-fg-stdout"
  f2544_f_foreground "quoted backslash path, worker stdout present" "$sid" "$(f2544_f_cmd "$sid" "$stem")" "$(f2544_worker_yaml pass)"
  sid="f2544-f-fg-empty"
  f2544_f_foreground "quoted backslash path, empty stdout" "$sid" "$(f2544_f_cmd "$sid" "$stem")" ""
  sid="f2544-f-fg-contradicting"
  f2544_f_foreground "quoted backslash path, stdout claims a failure" "$sid" "$(f2544_f_cmd "$sid" "$stem")" "$(f2544_worker_yaml fail)"
}

f2544_f_quoted_backslash_background() {
  local sid="f2544-f-bg" stem="$F2544_T-1"
  f2544_f_background "quoted backslash path, background" "$sid" "$(f2544_f_cmd "$sid" "$stem")"
}

f2544_f_unrecognised_command() {
  local sid="f2544-f-wrap-fg" stem="$F2544_T-1" cmd
  cmd="$(f2544_f_wrapped "$sid" "$stem")"
  f2544_eq "F/unrecognised: control — the wrapped dispatch is not a test command" \
    "$(f2544_probe is-test-command "$cmd")" "false"
  f2544_f_foreground "unrecognised command, foreground" "$sid" "$cmd" ""
  sid="f2544-f-wrap-bg"
  f2544_f_background "unrecognised command, background" "$sid" "$(f2544_f_wrapped "$sid" "$stem")"
}

# The background display command prints RUN_CONTRACT on stdout, yet must never be
# read as a test run by the stdout route.
f2544_f_display_is_not_a_test_command() {
  local script="$F2544_ROOT_N/skills/run-tests/scripts/show-dispatch-outcome.sh" cmd
  for cmd in "bash \"$script\" --session f2544-f-show" "bash $script --session f2544-f-show" \
    "bash \"${script//\//\\}\" --session f2544-f-show"; do
    f2544_eq "F/display: [$cmd] is not a test command" "$(f2544_probe is-test-command "$cmd")" "false"
  done
}

case_begin "show-dispatch-outcome-is-not-a-test-command" "hooks/workflow-run-tests.js"
f2544_f_display_is_not_a_test_command
case_end

case_begin "quoted-backslash-payload-path-is-recorded-via-outcome" "hooks/workflow-run-tests.js"
f2544_f_quoted_backslash_foreground
case_end

case_begin "quoted-backslash-background-dispatch-leaves-no-stale-complete" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_f_quoted_backslash_background
case_end

case_begin "path-notation-holds-for-an-unrecognised-command" "hooks/workflow-run-tests.js"
f2544_f_unrecognised_command
case_end

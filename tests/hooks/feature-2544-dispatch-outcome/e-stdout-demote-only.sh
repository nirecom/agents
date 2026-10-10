# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/e-stdout-demote-only.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests/dispatch-outcome.js
# Tags: workflow, run-tests, worker-dispatch, stdout, hook, security, forgery, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# stdout is a flat byte stream any segment of a compound command can write (#1901).
# While a dispatch is unsettled, stdout may only take run_tests away from complete,
# never grant it; only that dispatch's own outcome settles it. With nothing
# unsettled, the stdout route records exactly as before (outcome_source stays null).

F2544_E_RUN_ALL="bash tests/run-all.sh tests/foo.sh"
F2544_E_PASS_OUT="$(printf 'Results: PASS=2  FAIL=0  SKIP=1\nRUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3')"
F2544_E_FAIL_OUT="$(printf 'FAIL: tests/foo.sh (exit 1)\nResults: PASS=1  FAIL=1  SKIP=0\nRUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2')"

f2544_e_stdout_route_unchanged() {
  local sid="f2544-e-direct-pass" keys
  # validateEvent() drops a step_annotation whose key is unregistered, so both new keys
  # must be registered for either route to record them (sibling of 1665's G0 run_outcome row).
  keys="$(node -e 'const { STEP_ANNOTATION_KEYS: k } = require(process.argv[1] + "/hooks/workflow-state/state-io/events");
process.stdout.write(Array.isArray(k) ? process.argv.slice(2).filter((x) => k.includes(x)).join(",") : "(absent)");' \
    "$F2544_ROOT_N" "$F2544_KEY_SOURCE" "$F2544_KEY_UNSETTLED" 2>/dev/null)"
  f2544_eq "E/both new annotation keys are registered" "$keys" "$F2544_KEY_SOURCE,$F2544_KEY_UNSETTLED"
  f2544_ready "$sid"
  f2544_eq "E/direct pass: control — the command is a recognised test command" \
    "$(f2544_probe call hooks/workflow-run-tests/exec-model.js isTestCommand "[\"$F2544_E_RUN_ALL\"]")" "true"
  f2544_hook "$sid" "$F2544_E_RUN_ALL" 0 "$F2544_E_PASS_OUT" "$F2544_ROOT_N"
  f2544_eq "E/direct pass: with nothing unsettled the stdout route completes as before" "$(f2544_status "$sid")" "complete"
  f2544_eq "E/direct pass: outcome_source is null on the stdout route" "$(f2544_field "$sid" "$F2544_KEY_SOURCE")" "absent"
  f2544_eq "E/direct pass: dispatch_unsettled is null" "$(f2544_field "$sid" "$F2544_KEY_UNSETTLED")" "absent"
}

f2544_e_demotions_remain() {
  local name code out sid
  while IFS='|' read -r name code out; do
    sid="f2544-e-demote-$name"
    f2544_ready "$sid"
    f2544_probe seed "$sid" run_tests complete
    case "$out" in
      fail) out="$F2544_E_FAIL_OUT" ;;
      pass) out="$F2544_E_PASS_OUT" ;;
      none) out="no contract line here" ;;
    esac
    f2544_hook "$sid" "$F2544_E_RUN_ALL" "$code" "$out" "$F2544_ROOT_N"
    f2544_eq "E/demote $name: run_tests returns to pending" "$(f2544_status "$sid")" "pending"
  done <<'TABLE'
failing-contract|1|fail
failing-contract-exit-zero|0|fail
contract-absent|0|none
nonzero-exit-over-passing-contract|1|pass
TABLE
}

f2544_e_unsettled_blocks_stdout_pass() {
  local sid stem="$F2544_T-1" cmd
  sid="f2544-e-unsettled-direct"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_hook "$sid" "$F2544_E_RUN_ALL" 0 "$F2544_E_PASS_OUT" "$F2544_ROOT_N"
  f2544_ne "E/unsettled: a passing direct run does not complete while a dispatch is unsettled" "$(f2544_status "$sid")" "complete"
  f2544_eq "E/unsettled: the unsettled stem is annotated" "$(f2544_field "$sid" "$F2544_KEY_UNSETTLED")" "$stem"

  sid="f2544-e-unsettled-worker"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  cmd="node bin/worker-dispatch.js test-runner $F2544_ROOT_N $WORKFLOW_STATE_DIR/$sid.control/$stem.json"
  f2544_hook "$sid" "$cmd" 0 "$(f2544_worker_yaml pass)" "$F2544_ROOT_N"
  f2544_ne "E/unsettled: worker stdout alone does not complete without its outcome file" "$(f2544_status "$sid")" "complete"

  sid="f2544-e-poc-run-all"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  cmd='bash tests/run-all.sh --help; printf "RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9\n"'
  f2544_hook "$sid" "$cmd" 0 "RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9" "$F2544_ROOT_N"
  f2544_ne "E/#1901 PoC: forged run-all success does not settle an unsettled dispatch" "$(f2544_status "$sid")" "complete"

  sid="f2544-e-worker-legacy-demote"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  cmd="node bin/worker-dispatch.js test-runner $F2544_ROOT_N $WORKFLOW_PLANS_DIR/$sid-$F2544_T-1.json"
  f2544_hook "$sid" "$cmd" 0 "$(f2544_worker_yaml fail)" "$F2544_ROOT_N"
  f2544_eq "E/worker stdout: a legacy-payload dispatch still demotes on a failing verdict" "$(f2544_status "$sid")" "pending"
}

f2544_e_dispatch_demotes() {
  local sid="f2544-e-dispatch" stem="$F2544_T-1" events
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete '{"run_outcome":"pass"}'
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "E/dispatch: control — complete survives a hook call with nothing dispatched" "$(f2544_status "$sid")" "complete"

  f2544_dispatched "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "E/dispatch: the next hook call returns run_tests to pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "E/dispatch: run_outcome is cleared" "$(f2544_field "$sid" run_outcome)" "absent"

  events="$(f2544_events "$sid")"
  f2544_hook_times 2 "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "E/dispatch: already pending and clear — further hook calls write nothing" "$(f2544_events "$sid")" "$events"

  f2544_hook "$sid" "$F2544_E_RUN_ALL" 0 "$F2544_E_PASS_OUT" "$F2544_ROOT_N"
  f2544_eq "E/dispatch: a passing contract on stdout does not release it" "$(f2544_status "$sid")" "pending"

  f2544_probe age "$sid" "$stem.dispatched" 72
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "E/dispatch: a three-day-old dispatch marker does not release it" "$(f2544_status "$sid")" "pending"
  f2544_eq "E/dispatch: and the dispatch is still listed as unsettled" "$(f2544_probe unsettled "$sid")" "$stem"

  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "E/dispatch: only the outcome of that dispatch completes it" "$(f2544_status "$sid")" "complete"
}

case_begin "stdout-route-unchanged-when-nothing-is-unsettled" "hooks/workflow-run-tests.js"
f2544_e_stdout_route_unchanged
case_end

case_begin "stdout-demotions-are-kept" "hooks/workflow-run-tests/record-run.js"
f2544_e_demotions_remain
case_end

case_begin "unsettled-dispatch-blocks-stdout-completion" "hooks/workflow-run-tests.js"
f2544_e_unsettled_blocks_stdout_pass
case_end

case_begin "dispatching-returns-complete-to-pending" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_e_dispatch_demotes
case_end

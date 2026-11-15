# shellcheck shell=bash
# tests/bin/feature-3047-exceeds-budget/branch.sh
# Tests: bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, timeout, budget, branch, scope:issue-specific, pwsh-not-required, TL2
# T1/T3 on the branch stage's two exits (the post-run unrecordable timeout and budget 0). The duration
# ledger is written with run-all.sh's own writer functions and read by the real
# rtb_timeout_load_ledger; the stubbed run appends a timeout row mid-call, which the helper must not
# see until the next call. One function per case; the entrypoint wraps each in its case markers.

EB_T='tests/bin/t\.sh'
EB_BR_RUN='TESTS=("tests/bin/t.sh"); '
EB_BR_STAGE='eb_load; rtb_branch_stage; eb_report'
# u.sh (measured 10 s) runs first and consumes 400 s, so t.sh meets the budget-0 exit.
EB_BR_TWO='TESTS=("tests/bin/t.sh" "tests/bin/u.sh"); eb_seed tests/bin/u.sh 10 FAIL; '

# T1: completed 748 s > 403 s; requested 540 s cannot be applied, the run is unrecordable.
eb_branch_exceeds_after_run() {
  eb_drive "$TMPROOT/c-br-748" "${EB_BR_RUN}eb_seed tests/bin/t.sh 748 FAIL; $EB_BR_STAGE"
  eb_ck "the load saw the seeded completed row, not the stub's later timeout row" "M0 secs=748 term=completed" "$(eb_line M0)"
  eb_ck "the stage ran the test once" "CALLS=1" "$(eb_line CALLS=)"
  eb_ck "a completed measurement above the branch limit settles as exceeds-budget" \
    "R0 cls=undetermined det=exceeds-budget" "$(eb_line R0)"
  eb_has "stderr names the measurement and the 403 s branch limit" "$(eb_exceeds_line tests/bin/t.sh 748 403)"
  eb_lacks "exceeds-budget leaves no branch cache row" "CACHE tests/bin/t.sh"
}

# T1 (continued, same cache): the stub's timeout row is now the newest line, read at this call's start.
eb_branch_reread_next_call() {
  eb_drive "$TMPROOT/c-br-748" "${EB_BR_RUN}$EB_BR_STAGE"
  eb_ck "the next call reads the timeout row the previous call's run appended" "M0 secs=400 term=timeout" "$(eb_line M0)"
  eb_ck "the newest row is a timeout: budget-exhausted again" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "no exceeds-budget line on a timeout row" "exceeds budget:"
  eb_match "the budget-exhausted line says there is no completed measurement" "$(eb_no_measure_re "$EB_T" 'not-completed:timeout')"
}

# T1: the budget-0 exit, reached through elapsed time (TR_ADVANCE), not through RTB_BUDGET_TOTAL.
eb_branch_exceeds_budget_zero() {
  eb_drive "$TMPROOT/c-br-zero" "${EB_BR_TWO}eb_seed tests/bin/t.sh 748 FAIL; $EB_BR_STAGE" TR_ADVANCE=400
  eb_ck "only u.sh ran; t.sh met budget 0" "CALLS=1" "$(eb_line CALLS=)"
  eb_ck "budget 0 with a completed 748 s measurement: exceeds-budget" "R0 cls=undetermined det=exceeds-budget" "$(eb_line R0)"
  eb_has "stderr names the 403 s branch limit, not the remaining slice" "$(eb_exceeds_line tests/bin/t.sh 748 403)"
}

# T3: four shapes that stay budget-exhausted.
eb_branch_timeout_only() {
  eb_drive "$TMPROOT/c-br-tmo" "${EB_BR_RUN}eb_seed tests/bin/t.sh 400 TIMEOUT; $EB_BR_STAGE"
  eb_ck "timeout row only: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "timeout row only: no exceeds-budget line" "exceeds budget:"
  eb_match "timeout row only: the no-completed-measurement line" "$(eb_no_measure_re "$EB_T" 'not-completed:timeout')"
}

eb_branch_newest_timeout() {
  eb_drive "$TMPROOT/c-br-newest" "${EB_BR_RUN}eb_seed tests/bin/t.sh 748 FAIL; eb_seed tests/bin/t.sh 400 TIMEOUT; $EB_BR_STAGE"
  eb_ck "an older completed row is shadowed by the newer timeout row" "M0 secs=400 term=timeout" "$(eb_line M0)"
  eb_ck "newest row timeout: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "newest row timeout: no exceeds-budget line" "exceeds budget:"
}

eb_branch_unmeasured() {
  eb_drive "$TMPROOT/c-br-unm" "${EB_BR_TWO}$EB_BR_STAGE" TR_ADVANCE=400
  eb_ck "unmeasured at budget 0: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "unmeasured: no exceeds-budget line" "exceeds budget:"
  eb_match "unmeasured: the no-completed-measurement line" "$(eb_no_measure_re "$EB_T" unmeasured)"
}

eb_branch_within_limit() {
  eb_drive "$TMPROOT/c-br-300" "${EB_BR_RUN}eb_seed tests/bin/t.sh 300 FAIL; $EB_BR_STAGE"
  eb_ck "completed 300 s within the 403 s limit: budget-exhausted (converges on re-run)" \
    "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "within the limit: no exceeds-budget line" "exceeds budget:"
  eb_lacks "within the limit: no no-completed-measurement line" "has no completed measurement"
}

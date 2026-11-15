# shellcheck shell=bash
# tests/bin/feature-3047-exceeds-budget/base.sh
# Tests: bin/lib/run-tests-baseline-classify.sh
# Tags: run-tests, baseline, timeout, budget, base, scope:issue-specific, pwsh-not-required, TL2
# T1/T3 on the base's unrecordable-timeout exit (rtb_cls_base_timeout): the stubbed base run times
# out short of the requested value, and the helper settles the test from the measurement loaded at
# the call's start (limit 553 s, reserve 0). One function per case; the entrypoint wraps each.

EB_BS_RUN='TESTS=("tests/bin/t.sh"); '
# The base ran t.sh with 500 s of a requested 540 s and timed out: not recordable.
EB_BS_EXIT='eb_load; rtb_exec_one "$ROOT" tests/bin/t.sh 500 "$LOGDIR"; rtb_cls_base_timeout 0 tests/bin/t.sh 500 540 540; eb_report'

eb_base_exceeds() {
  eb_drive "$TMPROOT/c-bs-927" "${EB_BS_RUN}eb_seed tests/bin/t.sh 927 FAIL; $EB_BS_EXIT"
  eb_ck "the load saw the seeded completed row" "M0 secs=927 term=completed" "$(eb_line M0)"
  eb_ck "a completed 927 s measurement above the base limit: exceeds-budget" \
    "R0 cls=undetermined det=exceeds-budget" "$(eb_line R0)"
  eb_has "stderr names the 553 s base limit (reserve 0)" "$(eb_exceeds_line tests/bin/t.sh 927 553)"
}

# Same cache: the stub's mid-call timeout row is the newest line for the next call.
eb_base_reread_next_call() {
  eb_drive "$TMPROOT/c-bs-927" "${EB_BS_RUN}$EB_BS_EXIT"
  eb_ck "the next call reads the stub's timeout row" "M0 secs=400 term=timeout" "$(eb_line M0)"
  eb_ck "newest row timeout: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "no exceeds-budget line on a timeout row" "exceeds budget:"
}

eb_base_timeout_only() {
  eb_drive "$TMPROOT/c-bs-tmo" "${EB_BS_RUN}eb_seed tests/bin/t.sh 400 TIMEOUT; $EB_BS_EXIT"
  eb_ck "timeout row only: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "timeout row only: no exceeds-budget line" "exceeds budget:"
  eb_match "timeout row only: the no-completed-measurement line" "$(eb_no_measure_re 'tests/bin/t\.sh' 'not-completed:timeout')"
}

eb_base_newest_timeout() {
  eb_drive "$TMPROOT/c-bs-newest" "${EB_BS_RUN}eb_seed tests/bin/t.sh 927 FAIL; eb_seed tests/bin/t.sh 400 TIMEOUT; $EB_BS_EXIT"
  eb_ck "newest row timeout over an older completed one: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "newest row timeout: no exceeds-budget line" "exceeds budget:"
}

eb_base_unmeasured() {
  eb_drive "$TMPROOT/c-bs-unm" "${EB_BS_RUN}"'eb_load; rtb_exec_one "$ROOT" tests/bin/t.sh 250 "$LOGDIR"; rtb_cls_base_timeout 0 tests/bin/t.sh 250 300 300; eb_report'
  eb_ck "unmeasured: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "unmeasured: no exceeds-budget line" "exceeds budget:"
  eb_match "unmeasured: the no-completed-measurement line" "$(eb_no_measure_re 'tests/bin/t\.sh' unmeasured)"
}

eb_base_within_limit() {
  eb_drive "$TMPROOT/c-bs-500" "${EB_BS_RUN}eb_seed tests/bin/t.sh 500 FAIL; $EB_BS_EXIT"
  eb_ck "completed 500 s within the 553 s limit: budget-exhausted" "R0 cls=undetermined det=budget-exhausted" "$(eb_line R0)"
  eb_lacks "within the limit: no exceeds-budget line" "exceeds budget:"
  eb_lacks "within the limit: no no-completed-measurement line" "has no completed measurement"
}

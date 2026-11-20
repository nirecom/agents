# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-isolation/fault.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# Case bodies of the fault entrypoints. Compares the CLI with RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=fail|hang
# against variant expect (the shadow-off values; the isolation entrypoint checks they equal the off run).
# The entrypoint sources it after _lib.sh.

# si_fault_summary <label> <reason> — SUMMARY has skipped=<reason> and every test is counted as no_comparison.
si_fault_summary() {
  local s
  s="$(si_summary "$1")"
  case "$s" in
    *$'\tskipped='"$2"$'\t'*) pass "FAULT=$1: SUMMARY records skipped=$2" ;;
    *) fail "FAULT=$1: want SUMMARY with skipped=$2, got [$s]; stderr: ${SI_STDERR[$1]}" ;;
  esac
  case "$s" in
    *$'\tcompared=0\t'*$'\tno_comparison='"$SI_NTESTS"$'\t'*) pass "FAULT=$1: every failing test counts as no comparison" ;;
    *) fail "FAULT=$1: want compared=0 no_comparison=$SI_NTESTS, got [$s]" ;;
  esac
}

si_case_fault_fail() {
  si_run fail RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=fail
  si_same expect fail "FAULT=fail"
  si_fault_summary fail failed
  si_tmp_clean fail
}

# hang: the 10-second watchdog stops it, and SUMMARY has skipped=timed-out and an elapsed_ms of about 10 seconds.
si_case_fault_hang() {
  local ms
  si_run hang RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=hang
  if [ "${SI_RC[hang]}" != 124 ]; then pass "FAULT=hang: the CLI ended on its own in ${SI_SECS[hang]}s"
  else fail "FAULT=hang: the CLI was killed by the 120 s outer timeout"; fi
  si_same expect hang "FAULT=hang"
  si_fault_summary hang timed-out
  ms="$(si_summary hang | sed -n 's/.*elapsed_ms=\([0-9][0-9]*\).*/\1/p')"
  if [ -n "$ms" ] && [ "$ms" -ge 9000 ] && [ "$ms" -le 12000 ]; then pass "FAULT=hang: elapsed_ms=$ms is the 10 s cap"
  else fail "FAULT=hang: elapsed_ms [${ms:-none}] not within 9000-12000"; fi
  si_tmp_clean hang
}

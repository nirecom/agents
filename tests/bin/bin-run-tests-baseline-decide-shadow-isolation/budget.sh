# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-isolation/budget.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# Case bodies of the budget entrypoint. Advances SECONDS through env (the feature-3047 technique).
# 530: the exceeds-budget / budget-exhausted decisions are the same with the shadow on and off. With on, the shadow is not skipped and runs, and every test is outside-decide (skipped=-, compared=0).
# 590: what is left is under "the 10-second cap + 15 seconds", so the shadow does not run: skipped=budget-short.
# The entrypoint sources it after _lib.sh.

si_case_budget_same() {
  si_run b530off RUN_TESTS_BASELINE_DECIDE_SHADOW=off SECONDS=530
  si_run b530on SECONDS=530
  if printf '%s\n' "${SI_STDOUT[b530off]}" | grep -qE '^BASELINE: undetermined .*(budget-exhausted|exceeds-budget)'; then
    pass "fixture: SECONDS=530 makes the shadow-off run hit the budget"
  else
    fail "fixture: SECONDS=530 did not hit the budget: rc=${SI_RC[b530off]} stdout: ${SI_STDOUT[b530off]}"
  fi
  si_same b530off b530on "SECONDS=530 shadow on"
  si_budget_ran b530on
}

# si_budget_ran <label> — the shadow was not skipped and ran to the end: SUMMARY has skipped=- and every test is
# an outside-decide NO_COMPARISON (budget-exhausted / exceeds-budget are decided outside decide, so compared=0).
si_budget_ran() {
  local s f rows nout skp cmp nc
  s="$(si_summary "$1")"
  f="$(si_logs "$1" | head -n 1)"
  rows="$([ -n "$f" ] && grep '^NO_COMPARISON' "$f")"
  nout="$(printf '%s\n' "$rows" | grep -c $'\toutside-decide$')"
  skp="$(printf '%s\n' "$s" | tr '\t' '\n' | sed -n 's/^skipped=//p' | head -n 1)"
  cmp="$(printf '%s\n' "$s" | tr '\t' '\n' | sed -n 's/^compared=//p' | head -n 1)"
  nc="$(printf '%s\n' "$s" | tr '\t' '\n' | sed -n 's/^no_comparison=//p' | head -n 1)"
  if [[ "$skp" == "-" && "$cmp" == "0" && "$nc" == "$SI_NTESTS" && "$nout" -eq "$SI_NTESTS" ]]; then
    pass "$1: the shadow ran (skipped=-) and every test is NO_COMPARISON outside-decide"
  else
    fail "$1: want skipped=- compared=0 no_comparison=$SI_NTESTS all outside-decide, got [$s]; log: [$rows]; stderr: ${SI_STDERR[$1]}"
  fi
}

si_case_budget_short() {
  local s
  si_run b590 SECONDS=590
  s="$(si_summary b590)"
  case "$s" in
    *$'\tcompared=0\t'*$'\tno_comparison='"$SI_NTESTS"$'\tskipped=budget-short\t'*)
      pass "SECONDS=590: SUMMARY records skipped=budget-short with every test uncompared" ;;
    *) fail "SECONDS=590: want compared=0 no_comparison=$SI_NTESTS skipped=budget-short, got [$s]; stderr: ${SI_STDERR[b590]}" ;;
  esac
  if [ "$(si_shadow_err_lines b590 | grep -c .)" -eq 1 ]; then pass "SECONDS=590: the one decide shadow stderr line is still written"
  else fail "SECONDS=590: want one decide shadow stderr line, got [$(si_shadow_err_lines b590)]"; fi
  si_tmp_clean b590
}

# A `find` that sleeps 30 s stands in for a slow log retention sweep. The sweep and the input TSV write belong
# under the cap, so (b) still returns within the 10-second cap plus the 2-second KILL grace (asserted <= 15 s).
si_case_pre_cap_work_capped() {
  local work="$TMPROOT/precap" shim="$TMPROOT/precap-shim" out rc=0 el err
  mkdir -p "$work" "$shim"
  printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' >"$shim/find"
  chmod +x "$shim/find"
  out="$(cd "$TMPROOT" && env PRECAP_SHIM="$shim" bash "$SI_RWT" 90 bash "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-run-tests-baseline-decide-shadow-wrapper/driver.sh" \
    "$work" "$work" "$work" '
. "$DRV_SHADOW_LIB" || { echo "DRV_ERR shadow lib failed to source"; exit 0; }
TESTS=(tests/bin/x.sh); RUN_REL=(tests/bin/x.sh); CLS=(broken); DET=(passes-at-base)
ROOT="$WORK"; LOGDIR="$WORK/logs-1-1"; export RUN_ALL_CACHE_DIR="$WORK/cache"; unset RTB_BUDGET_TOTAL
PATH="$PRECAP_SHIM:$PATH"
t0=$SECONDS
rtb_decide_shadow_compare_before_handoff 2>"$WORK/handoff.err"
echo "ELAPSED $((SECONDS - t0))"' 2>&1)" || rc=$?
  el="$(printf '%s\n' "$out" | sed -n 's/^ELAPSED //p' | head -n 1)"
  err="$(cat "$work/handoff.err" 2>/dev/null)"
  if [[ -n "$el" && "$el" -le 15 ]]; then pass "a slow pre-cap find still returns within the cap: ${el}s"
  else fail "rtb_decide_shadow_compare_before_handoff took [${el:-none}]s with a 30 s find (want <= 15); rc=$rc out: $out"; fi
  if [[ "$(printf '%s\n' "$err" | grep -c '^run-tests-baseline: decide shadow: ')" -eq 1 ]]; then
    pass "the one decide shadow stderr line is still written"
  else
    fail "want one decide shadow stderr line, got [$err]"
  fi
}

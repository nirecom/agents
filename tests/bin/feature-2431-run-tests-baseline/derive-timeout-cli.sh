# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/derive-timeout-cli.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, timeout, ledger, cli, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone. Needs derive-timeout.sh (dt_seed_dur) and
# cli-homeref.sh (ch_repo_begin, ch_repo_end, ch_mk_test, ch_assert_preexisting) sourced first.
# #2547 CLI group: the diagnostic line `run-tests-baseline: timeout: <test> <n>s (<source>)` is the
# observation window for the value handed to rtb_exec_one; no case waits for a real 300 s.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

# dt_cli_run <cache> <repo> <sid> [VAR=val...] [-- flags...] — the CLI without a default
# --per-test-timeout; sets RTB_CLI_RC / RTB_CLI_OUT (stdout+stderr). VAR=val reaches the child only.
dt_cli_run() {
  local cache="$1" repo="$2" sid="$3"; shift 3
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  RTB_CLI_RC=0
  RTB_CLI_OUT="$(cd "$TMPROOT" && run_with_timeout 120 env RUN_ALL_CACHE_DIR="$cache" ${envs[@]+"${envs[@]}"} \
    bash "$BASELINE_CLI" --session "$sid" --worktree "$repo" "$@" 2>&1)" || RTB_CLI_RC=$?
}

# dt_case <label> <secs-or-empty> [VAR=val...] [-- flags...] — fixture repo with one failing test
# (sentinel on execution), optional ledger seed, then the CLI. Sets DT_T, DT_RAN, DT_SID.
dt_case() {
  local label="$1" secs="$2"; shift 2
  local repo="$TMPROOT/repo-dt-$label" cache
  DT_T="tests/bin/test-dt-$label.sh" DT_RAN="$TMPROOT/dt-$label-executed" DT_SID="dt-$label-$$"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$DT_T" "$DT_RAN"
  ch_repo_end "$repo"
  cache="$(cli_case_cache "dt-$label")"
  [ -z "$secs" ] || dt_seed_dur "$cache" "$repo" "$DT_T" "$secs" || fail "$label: could not seed the duration ledger"
  seed_failing "$DT_SID" "$DT_T"
  dt_cli_run "$cache" "$repo" "$DT_SID" "$@"
}

# dt_assert_timeout_line <label> <test> <text> — the diagnostic line names the value and its source.
dt_assert_timeout_line() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qF "run-tests-baseline: timeout: $2 $3"; then
    pass "$1: diagnostic line '$2 $3'"
  else
    fail "$1: no diagnostic line '$2 $3'; rc=$RTB_CLI_RC ($(printf '%s\n' "$RTB_CLI_OUT" | grep 'timeout:' | tr '\n' '|'))"
  fi
}

# dt_assert_budget_exhausted <label> — never executed, undetermined budget-exhausted, run_tests pending.
dt_assert_budget_exhausted() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$DT_T[[:space:]]+budget-exhausted"; then
    pass "$1: classified undetermined budget-exhausted"
  else
    fail "$1: expected undetermined budget-exhausted; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if [ ! -e "$DT_RAN" ]; then
    pass "$1: the test body was never executed"
  else
    fail "$1: the test body ran despite an exhausted budget (sentinel exists)"
  fi
  cli_assert_undetermined_only "$1" "$DT_T"
  cli_assert_not_completed "$1" "$DT_SID" "$DT_T"
}

# Two failing tests share one budget: with TOTAL=100 (deadline 55) the first one (25 s) leaves less than
# MIN_SLICE (30 s) for the second, which is budget-exhausted and never run; a rerun with the full budget
# serves the first from the ledger and runs only the second.
dt_shared_budget_cases() {
  local repo="$TMPROOT/repo-dt-shared" cache sid="dt-shared-$$"
  local t1="tests/bin/test-dt-shared-a.sh" t2="tests/bin/test-dt-shared-b.sh"
  local ran1="$TMPROOT/dt-shared-a-executed" ran2="$TMPROOT/dt-shared-b-executed"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t1" "$ran1" 'sleep 25'
  ch_mk_test "$repo" "$t2" "$ran2"
  ch_repo_end "$repo"
  cache="$(cli_case_cache dt-shared)"
  seed_failing "$sid" "$t1" "$t2"
  dt_cli_run "$cache" "$repo" "$sid" RTB_BUDGET_TOTAL=100
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t1[[:space:]]+fails-at-base-exit-1" && [ -e "$ran1" ]; then
    pass "S1: the first test ran and was classified preexisting"
  else
    fail "S1: first test not classified; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t2[[:space:]]+budget-exhausted" && [ ! -e "$ran2" ]; then
    pass "S2: the second test is budget-exhausted and was never executed"
  else
    fail "S2: second test should be budget-exhausted and unexecuted; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_not_completed "S3" "$sid" "$t2"
  rm -f "$ran1"
  dt_cli_run "$cache" "$repo" "$sid"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t2[[:space:]]+fails-at-base-exit-1" && [ -e "$ran2" ]; then
    pass "S4: with the full budget the second test runs and is classified preexisting"
  else
    fail "S4: rerun did not run the second test; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if [ ! -e "$ran1" ] && [ -e "$ran2" ]; then
    pass "S5: the rerun executed only the second test; the first came from the saved classification"
  else
    fail "S5: expected only the second test to run on the rerun (first ran=$([ -e "$ran1" ] && echo yes || echo no), second ran=$([ -e "$ran2" ] && echo yes || echo no))"
  fi
  cli_assert_completed "S4" "$sid"
}

# A value beyond Bash's integer range must never surface an arithmetic error: either a usage error
# (exit 2, nothing classified) or a budget-limited slice (30..553) with the test run. Either is safe.
dt_huge_explicit_case() {
  local slice
  dt_case huge "" -- --per-test-timeout 99999999999999999999
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qiE 'value too great|syntax error|integer expression|unbound variable|bad substitution|overflow'; then
    fail "HG1: an arithmetic or shell error leaked: $(printf '%s\n' "$RTB_CLI_OUT" | grep -iE 'value too great|syntax error|integer expression|unbound variable|bad substitution|overflow' | head -n 2 | tr '\n' '|')"
    return
  fi
  slice="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n "s|^run-tests-baseline: timeout: ${DT_T//./\\.} \([0-9]*\)s (explicit.*\$|\1|p")"
  if [ "$RTB_CLI_RC" -eq 2 ] && [ ! -e "$DT_RAN" ] && ! printf '%s\n' "$RTB_CLI_OUT" | grep -q '^BASELINE'; then
    pass "HG1: 20-digit --per-test-timeout rejected as a usage error (exit 2), nothing executed"
  elif [[ "$slice" =~ ^[0-9]+$ ]] && [ "$slice" -ge 30 ] && [ "$slice" -le 553 ] && [ -e "$DT_RAN" ]; then
    pass "HG1: 20-digit --per-test-timeout cut to slice $slice (30..553) and the test ran"
  else
    fail "HG1: expected exit 2 or a 30..553 slice with the test run; rc=$RTB_CLI_RC slice='$slice' ($(cli_baseline_lines))"
  fi
}

run_timeout_cli_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    fail "DT: bin/run-tests-baseline not found (impl pending)"
    return
  fi
  local repo cache slice

  # ---- (d) an explicit --per-test-timeout beats a derived 540 (ledger says 400s) ----
  repo="$TMPROOT/repo-dt-explicit"
  mk_fixture_repo "$repo" >/dev/null
  cache="$(cli_case_cache dt-explicit)"
  dt_seed_dur "$cache" "$repo" tests/bin/test-sleep.sh 400 || fail "D1: could not seed the duration ledger"
  seed_failing "dt-d-$$" tests/bin/test-sleep.sh
  dt_cli_run "$cache" "$repo" "dt-d-$$" -- --per-test-timeout 1
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE: undetermined[[:space:]]+tests/bin/test-sleep.sh.*timeout-at-base' \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "D1: explicit 1s timed the sleeping test out (timeout-at-base), exit 1"
  else
    fail "D1: expected timeout-at-base + exit 1; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  dt_assert_timeout_line "D2" tests/bin/test-sleep.sh "1s (explicit)"

  # ---- (e) budget exhausted: the test is not run, for the derived and the explicit path ----
  dt_case e-derived "" RTB_BUDGET_TOTAL=50
  dt_assert_budget_exhausted "E-CLI1 (derived path, TOTAL=50)"
  dt_case e-explicit "" RTB_BUDGET_TOTAL=50 -- --per-test-timeout 10
  dt_assert_budget_exhausted "E-CLI2 (explicit path, TOTAL=50)"

  # ---- (f) the derived value reaches the diagnostic line; the test still runs and completes ----
  dt_case f-long 400
  dt_assert_timeout_line "F1" "$DT_T" "540s (derived)"
  ch_assert_preexisting "F1" "$DT_T" "$DT_RAN" "$DT_SID"
  dt_case f-short 5
  dt_assert_timeout_line "F2" "$DT_T" "300s (derived)"
  ch_assert_preexisting "F2" "$DT_T" "$DT_RAN" "$DT_SID"
  dt_case f-limited 400 RTB_BUDGET_TOTAL=300
  # TOTAL=300 -> deadline 255; slice = 255 - elapsed - 2 <= 253 and, for a start-up under 223s, >= 30.
  slice="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n "s|^run-tests-baseline: timeout: ${DT_T//./\\.} \([0-9]*\)s (derived, limited from 540s by budget)\$|\1|p")"
  if [[ "$slice" =~ ^[0-9]+$ ]] && [ "$slice" -ge 30 ] && [ "$slice" -le 253 ]; then
    pass "F3: diagnostic line shows the budget-limited slice $slice (30..253) of the derived 540s"
  else
    fail "F3: no 'limited from 540s by budget' diagnostic; rc=$RTB_CLI_RC ($(printf '%s\n' "$RTB_CLI_OUT" | grep 'timeout:' | tr '\n' '|'))"
  fi
  ch_assert_preexisting "F3" "$DT_T" "$DT_RAN" "$DT_SID"

  # ---- (g) unmeasured test: fallback 300, behaves as before ----
  dt_case g-unmeasured ""
  dt_assert_timeout_line "G1" "$DT_T" "300s (default)"
  ch_assert_preexisting "G1" "$DT_T" "$DT_RAN" "$DT_SID"

  # ---- explicit 590 is cut by the budget (deadline 555 - 2 -> about 553, varies with elapsed seconds) ----
  dt_case x590 "" -- --per-test-timeout 590
  slice="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n "s|^run-tests-baseline: timeout: ${DT_T//./\\.} \([0-9]*\)s (explicit, limited from 590s by budget)\$|\1|p")"
  if [[ "$slice" =~ ^[0-9]+$ ]] && [ "$slice" -ge 30 ] && [ "$slice" -le 553 ]; then
    pass "X1: explicit 590 is limited by the budget to $slice (30..553)"
  else
    fail "X1: no 'explicit, limited from 590s by budget' diagnostic; rc=$RTB_CLI_RC ($(printf '%s\n' "$RTB_CLI_OUT" | grep 'timeout:' | tr '\n' '|'))"
  fi
  ch_assert_preexisting "X1" "$DT_T" "$DT_RAN" "$DT_SID"

  dt_huge_explicit_case
  dt_shared_budget_cases

  # ---- (h'') the value shown is the value handed to rtb_exec_one ----
  if grep -qE 'rtb_exec_one[^#]*"\$T_USE"' "$BASELINE_CLI"; then
    pass "H6: rtb_exec_one is called with \"\$T_USE\""
  else
    fail "H6: the rtb_exec_one call in bin/run-tests-baseline does not pass \"\$T_USE\""
  fi
  if grep -E 'timeout: ' "$BASELINE_CLI" | grep -qF '$T_USE'; then
    pass "H7: the diagnostic line prints the same T_USE variable"
  else
    fail "H7: the diagnostic line does not print \$T_USE"
  fi
}

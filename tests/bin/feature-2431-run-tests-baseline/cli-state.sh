# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli-state.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, test-result-contract, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher after cli.sh and exec-state.sh; never run standalone.
# #2501: a base state decides (FAIL 124/142 preexisting, 137/143 ambiguous, UNRUNNABLE
# unrunnable-at-base); a legacy launcher with no state keeps the exit-code classification.

# amb_repo <repo> [<launcher>] — base adds tests/bin/test-exit-<rc>.sh per ambiguous rc,
# plus <launcher> as bin/lib/run-all-launch.sh when given.
amb_repo() {
  local repo="$1" launcher="${2:-}" rc
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  for rc in 124 137 142 143; do
    printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$repo/tests/bin/test-exit-$rc.sh"
    chmod +x "$repo/tests/bin/test-exit-$rc.sh"
  done
  git -C "$repo" add tests/
  if [ -n "$launcher" ]; then
    mkdir -p "$repo/bin/lib"
    cp "$launcher" "$repo/bin/lib/run-all-launch.sh"
    git -C "$repo" add bin/lib/run-all-launch.sh
  fi
  git -C "$repo" commit -q -m "ambiguous-exit tests at base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
}

# amb_expect_ambiguous <label> <repo> <rc> <sid-prefix> — the test exiting <rc> is undetermined
# ambiguous-exit-<rc>, never preexisting, and run_tests does not complete.
amb_expect_ambiguous() {
  local t="tests/bin/test-exit-$3.sh"
  seed_failing "$4$3-$$" "$t"
  rtb_cli_run "$(cli_case_cache "$4$3")" "$2" "$4$3-$$"
  if printf '%s\n' "$RTB_CLI_OUT" \
      | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+ambiguous-exit-$3\$"; then
    pass "$1-$3: exit $3 at base classified undetermined ambiguous-exit-$3"
  else
    fail "$1-$3: expected undetermined ambiguous-exit-$3; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_undetermined_only "$1-$3" "$t"
  cli_assert_not_completed "$1-$3" "$4$3-$$" "$t"
}

# With a state (the current launcher, used because the base has none of its own): the test
# exits the code itself, well inside the timeout, so the launcher reports FAIL.
run_cli_ambiguous_exit_cases() {
  local repo="$TMPROOT/repo-ambig" rc t
  amb_repo "$repo"
  for rc in 124 142; do
    t="tests/bin/test-exit-$rc.sh"
    seed_failing "amb$rc-$$" "$t"
    rtb_cli_run "$(cli_case_cache "amb$rc")" "$repo" "amb$rc-$$"
    # The detail after the path is the CLI's to word; the class is the contract.
    if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t([[:space:]]|\$)" \
      && printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=0$' \
      && [ "$RTB_CLI_RC" -eq 0 ]; then
      pass "C3-state-fail-exit-$rc: FAIL state with exit $rc at base is preexisting, exit 0"
    else
      fail "C3-state-fail-exit-$rc: expected preexisting + summary preexisting=1 + exit 0; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
    fi
  done
  for rc in 137 143; do
    amb_expect_ambiguous "C3-ambiguous-exit" "$repo" "$rc" amb
  done
}

# A legacy base launcher (sets no RUN_ALL_EXEC_STATE) keeps the exit-code classification.
run_cli_legacy_launcher_cases() {
  local repo="$TMPROOT/repo-legacy" stub="$TMPROOT/legacy-launch.sh" rc
  printf '%s\n' 'run_all_exec() { RUN_ALL_EXEC_LAUNCHED=1; bash "$1" >"$2" 2>"$3" </dev/null; }' > "$stub"
  amb_repo "$repo" "$stub"
  for rc in 124 137 142 143; do
    amb_expect_ambiguous "C3-legacy-launcher" "$repo" "$rc" leg
  done
}

# A base launcher whose own setup failed (state FAIL, rc 2, not launched) never ran the test: the
# CLI says undetermined exec-setup-failed, never preexisting. A launched test exiting 2 is preexisting.
run_cli_launcher_setup_failed_cases() {
  local repo stub="$TMPROOT/setup-failed-launch.sh" t="tests/bin/test-preexisting.sh" launched
  for launched in 0 1; do
    repo="$TMPROOT/repo-lsf$launched"
    printf 'run_all_exec() { RUN_ALL_EXEC_STATE=FAIL RUN_ALL_EXEC_RC=2 RUN_ALL_EXEC_LAUNCHED=%s; return 2; }\n' \
      "$launched" > "$stub"
    amb_repo "$repo" "$stub"
    seed_failing "lsf$launched-$$" "$t"
    rtb_cli_run "$(cli_case_cache "lsf$launched")" "$repo" "lsf$launched-$$"
    if [ "$launched" = 0 ]; then
      if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+exec-setup-failed"; then
        pass "C3-launcher-setup-failed: not-launched rc 2 at base classified undetermined exec-setup-failed"
      else
        fail "C3-launcher-setup-failed: expected undetermined exec-setup-failed; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
      fi
      cli_assert_undetermined_only "C3-launcher-setup-failed" "$t"
      cli_assert_not_completed "C3-launcher-setup-failed" "lsf$launched-$$" "$t"
    elif printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t([[:space:]]|\$)"; then
      pass "C3-launched-exit-2: a launched test exiting 2 at base is preexisting"
    else
      fail "C3-launched-exit-2: expected preexisting; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
    fi
  done
}

# A base table whose bash entry requires a missing tool: the base test is UNRUNNABLE, so the CLI
# says undetermined unrunnable-at-base and run_tests does not complete.
run_cli_unrunnable_at_base_cases() {
  local repo="$TMPROOT/repo-unrun" t="tests/bin/test-preexisting.sh"
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  if ! mk_unrunnable_checkout "$repo"; then
    fail "C3-unrunnable-at-base: fixture error — could not install the registry"
    return
  fi
  git -C "$repo" add bin hooks
  git -C "$repo" commit -q -m "base launcher whose bash entry requires a missing tool"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  seed_failing "unr-$$" "$t"
  rtb_cli_run "$(cli_case_cache unr)" "$repo" "unr-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+unrunnable-at-base"; then
    pass "C3-unrunnable-at-base: missing tool at base classified undetermined unrunnable-at-base"
  else
    fail "C3-unrunnable-at-base: expected undetermined unrunnable-at-base; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_undetermined_only "C3-unrunnable-at-base" "$t"
  cli_assert_not_completed "C3-unrunnable-at-base" "unr-$$" "$t"
}

# A legacy base launcher (no state) whose failing file's CURRENT registry entry has a
# launch.wrapper: the old rc is not a converted result, so undetermined, never preexisting.
run_cli_legacy_launcher_wrapper_cases() {
  local repo="$TMPROOT/repo-legwrap" stub="$TMPROOT/legacy-wrap-launch.sh" t="tests/bin/legacy-wrap.Tests.ps1"
  printf '%s\n' 'run_all_exec() { RUN_ALL_EXEC_LAUNCHED=1; bash "$1" >"$2" 2>"$3" </dev/null; }' > "$stub"
  amb_repo "$repo" "$stub"
  git -C "$repo" checkout -q main
  printf 'exit 1\n' > "$repo/$t"
  git -C "$repo" add "$t"
  git -C "$repo" commit -q -m "wrapper-language test at base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  seed_failing "lwr-$$" "$t"
  rtb_cli_run "$(cli_case_cache lwr)" "$repo" "lwr-$$"
  if printf '%s\n' "$RTB_CLI_OUT" \
      | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+base-launcher-predates-result-conversion\$"; then
    pass "C3-legacy-launcher-wrapper: wrapper entry under a stateless base launcher is undetermined"
  else
    fail "C3-legacy-launcher-wrapper: expected undetermined base-launcher-predates-result-conversion; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_undetermined_only "C3-legacy-launcher-wrapper" "$t"
  cli_assert_not_completed "C3-legacy-launcher-wrapper" "lwr-$$" "$t"
}

# Every failure pre-existed, but the run left a test unrun (unrunnable_count 1): the evidence
# refuses completion, its reason reaches the user, and the CLI names the evidence exit.
run_cli_evidence_unmet_cases() {
  local repo="$TMPROOT/repo-evunmet" t="tests/bin/test-preexisting.sh"
  mk_fixture_repo "$repo" >/dev/null
  SEED_UNRUNNABLE=1 seed_failing "evu-$$" "$t"
  rtb_cli_run "$(cli_case_cache evu)" "$repo" "evu-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t([[:space:]]|\$)" \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "C3-evidence-unmet: preexisting classification, exit 1"
  else
    fail "C3-evidence-unmet: expected preexisting + exit 1; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  case "$RTB_CLI_OUT" in
    *"run_tests was not completed (evidence exit 1; its reason is above)"*)
      pass "C3-evidence-unmet: die names the evidence exit" ;;
    *) fail "C3-evidence-unmet: die message missing; out=$(printf '%s' "$RTB_CLI_OUT" | tail -n 3)" ;;
  esac
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qi 'unrunnable'; then
    pass "C3-evidence-unmet: the evidence reason names unrunnable"
  else
    fail "C3-evidence-unmet: evidence reason does not reach the output; out=$(printf '%s' "$RTB_CLI_OUT" | tail -n 3)"
  fi
  local st
  st="$(read_step_field "evu-$$" run_tests status)"
  [ "$st" = '"pending"' ] && pass "C3-evidence-unmet: run_tests stays pending" \
    || fail "C3-evidence-unmet: run_tests must stay pending despite unrunnable_count 1; status=$st"
}

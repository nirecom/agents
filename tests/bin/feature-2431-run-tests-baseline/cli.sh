# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# Plan contract: bin/run-tests-baseline --session <sid> [--worktree <path>] [--per-test-timeout <s>]
# prints `BASELINE: <class> <path> [detail]` + `BASELINE_SUMMARY: preexisting=N inherited=N
# broken=N undetermined=N`; exit 0 all-preexisting, 1 otherwise, 3 no failing list, 4 bad base.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

# cli_case_cache <label> — a fresh ledger/cache dir per case, so no case reuses another's records.
cli_case_cache() {
  mkdir -p "$TMPROOT/cache-cli-$1"
  printf '%s\n' "$TMPROOT/cache-cli-$1"
}

cli_baseline_lines() { printf '%s\n' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|'; }

run_cli_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    local id
    for id in C1 C2 C3 C4 C5 C6 C7 C8 C9 C10; do
      fail "$id: bin/run-tests-baseline not found (impl pending)"
    done
    return
  fi
  local repo="$TMPROOT/repo-cli"
  mk_fixture_repo "$repo" >/dev/null

  # ---- C1: exit 3 when run_tests is not pending ----
  local sid_c1="c1-$$"
  run_with_timeout 20 node -e "
const { appendEvents } = require(process.argv[1] + '/hooks/workflow-state/state-io/events');
appendEvents(process.argv[2], [{kind:'step_status',step:'run_tests',status:'complete',
  provenance:'observed',origin:'run-tests-hook'}]);
" "$AGENTS_WIN" "$sid_c1" >/dev/null 2>&1 || true
  rtb_cli_run "$(cli_case_cache c1)" "$repo" "$sid_c1" --per-test-timeout 3
  [ "$RTB_CLI_RC" -eq 3 ] && pass "C1: exit 3 when run_tests is not pending" \
    || fail "C1: expected exit 3, got $RTB_CLI_RC"

  # ---- C2: exit 3 when failing_tests is absent ----
  local sid_c2="c2-$$"
  run_with_timeout 20 node -e "
const { appendEvents } = require(process.argv[1] + '/hooks/workflow-state/state-io/events');
appendEvents(process.argv[2], [
  {kind:'step_status',step:'run_tests',status:'pending',provenance:'observed',origin:'run-tests-hook'},
  {kind:'step_annotation',step:'run_tests',key:'run_outcome',value:'fail',
   provenance:'observed',origin:'run-tests-hook'}
]);
" "$AGENTS_WIN" "$sid_c2" >/dev/null 2>&1 || true
  rtb_cli_run "$(cli_case_cache c2)" "$repo" "$sid_c2" --per-test-timeout 3
  [ "$RTB_CLI_RC" -eq 3 ] && pass "C2: exit 3 when failing_tests absent" \
    || fail "C2: expected exit 3 (no failing_tests), got $RTB_CLI_RC"

  # ---- C3–C6: all-preexisting run ----
  local t_pre="tests/bin/test-preexisting.sh"
  seed_failing "c3-$$" "$t_pre"
  rtb_cli_run "$(cli_case_cache c3)" "$repo" "c3-$$"
  [ "$RTB_CLI_RC" -eq 0 ] && pass "C3: exit 0 when all failing tests are preexisting" \
    || fail "C3: expected exit 0, got $RTB_CLI_RC ($(cli_baseline_lines))"
  printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t_pre" \
    && pass "C4: BASELINE: <class> <path> line shows preexisting" \
    || fail "C4: no 'BASELINE: preexisting $t_pre' line ($(cli_baseline_lines))"
  printf '%s\n' "$RTB_CLI_OUT" \
    | grep -qE '^BASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=0$' \
    && pass "C5: BASELINE_SUMMARY counts match" \
    || fail "C5: BASELINE_SUMMARY missing or wrong ($(cli_baseline_lines))"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^(RUN_CONTRACT:|FAIL:)'; then
    fail "C6: child RUN_CONTRACT:/FAIL: lines leaked to CLI output"
  else
    pass "C6: no RUN_CONTRACT:/FAIL: lines in CLI output"
  fi

  # ---- C7/C8: passes at base → broken, exit 1 ----
  local t_brk="tests/bin/test-broken.sh"
  seed_failing "c7-$$" "$t_brk"
  rtb_cli_run "$(cli_case_cache c7)" "$repo" "c7-$$"
  [ "$RTB_CLI_RC" -eq 1 ] && pass "C7: exit 1 when a test is broken" \
    || fail "C7: expected exit 1 (broken test), got $RTB_CLI_RC"
  printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: broken[[:space:]]+$t_brk" \
    && pass "C8: BASELINE: line shows broken" \
    || fail "C8: broken classification missing ($(cli_baseline_lines))"

  # ---- C9: per-test timeout → undetermined (timeout-at-base), never preexisting ----
  local t_slp="tests/bin/test-sleep.sh"
  seed_failing "c9-$$" "$t_slp"
  rtb_cli_run "$(cli_case_cache c9)" "$repo" "c9-$$" --per-test-timeout 1
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_slp.*timeout-at-base" \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "C9: timeout-at-base → undetermined, exit 1"
  else
    fail "C9: expected undetermined timeout-at-base + exit 1, rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi

  # ---- C10: FALLBACK merge-base (no main, HEAD~1 only) → exit 4 passed through ----
  local repo_c10="$TMPROOT/repo-c10" i
  git init -q "$repo_c10"
  git -C "$repo_c10" config core.hooksPath /dev/null
  git -C "$repo_c10" config user.email test@example.com
  git -C "$repo_c10" config user.name Test
  git -C "$repo_c10" config commit.gpgsign false
  git -C "$repo_c10" config core.autocrlf false
  git -C "$repo_c10" symbolic-ref HEAD refs/heads/feature
  for i in 1 2; do
    printf '%s\n' "$i" > "$repo_c10/x.txt"
    git -C "$repo_c10" add x.txt
    git -C "$repo_c10" commit -q -m "c$i"
  done
  seed_failing "c10-$$" "$t_pre"
  rtb_cli_run "$(cli_case_cache c10)" "$repo_c10" "c10-$$" --per-test-timeout 3
  if [ "$RTB_CLI_RC" -eq 4 ] && ! printf '%s\n' "$RTB_CLI_OUT" | grep -q '^BASELINE: '; then
    pass "C10: FALLBACK merge-base → exit 4 before any classification"
  else
    fail "C10: expected exit 4 with no BASELINE: lines, got $RTB_CLI_RC ($(cli_baseline_lines))"
  fi
}

# Plan step 5: a failing test absent at the merge-base is `undetermined` (missing-at-base),
# never `preexisting`. Distinct from C10 (merge-base itself unusable).
run_cli_missing_at_base_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    fail "C3-missing-at-base: bin/run-tests-baseline not found (impl pending)"
    return
  fi
  local repo="$TMPROOT/repo-mab"
  local t_new="tests/bin/test-new.sh" t_pre="tests/bin/test-preexisting.sh"
  mk_fixture_repo "$repo" >/dev/null
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/$t_new"
  chmod +x "$repo/$t_new"
  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "add new failing test"
  if git -C "$repo" cat-file -e "main:$t_new" 2>/dev/null; then
    fail "C3-missing-at-base: fixture error — $t_new exists at the merge-base"
    return
  fi

  seed_failing "mab-$$" "$t_new" "$t_pre"
  rtb_cli_run "$(cli_case_cache mab)" "$repo" "mab-$$"
  local summary="rc=$RTB_CLI_RC out=$(cli_baseline_lines)"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_new" \
    && ! printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[^ ]*[[:space:]]+$t_new"; then
    pass "C3-missing-at-base: test absent at base classified undetermined, not preexisting"
  else
    fail "C3-missing-at-base: expected undetermined for $t_new; $summary"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_new.*missing-at-base"; then
    pass "C3-missing-at-base: detail names missing-at-base"
  else
    fail "C3-missing-at-base: detail missing-at-base absent; $summary"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t_pre" \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "C3-missing-at-base: control test preexisting and overall exit 1 (not all preexisting)"
  else
    fail "C3-missing-at-base: control/exit mismatch; $summary"
  fi
  cli_assert_not_completed "C3-missing-at-base" "mab-$$" "$t_new"
}

# cli_assert_not_completed <label> <sid> <undetermined-path> — an undetermined verdict must
# leave run_tests pending with no completion_basis and a non-zero exit. The recorded
# baseline_classification naming the path as undetermined proves the record step ran and
# refused, so the pending status is not vacuous (record never invoked).
cli_assert_not_completed() {
  local st basis bc
  st="$(read_step_field "$2" run_tests status)"
  basis="$(read_step_field "$2" run_tests completion_basis)"
  bc="$(read_step_field "$2" run_tests baseline_classification)"
  if [ "$st" = '"pending"' ] && [ "$basis" = "(absent)" ] && [ "$RTB_CLI_RC" -ne 0 ]; then
    pass "$1: run_tests stays pending, no completion_basis, exit non-zero"
  else
    fail "$1: run_tests must not complete; status=$st basis=$basis rc=$RTB_CLI_RC"
  fi
  if printf '%s' "$bc" | grep -qF "$3" && printf '%s' "$bc" | grep -qF 'undetermined'; then
    pass "$1: baseline_classification recorded $3 as undetermined (record refused completion)"
  else
    fail "$1: baseline_classification missing or not undetermined for $3; got=$bc"
  fi
}

# cli_assert_undetermined_only <label> <path> — the single failing test is undetermined:
# never preexisting, summary counts it as undetermined, overall exit exactly 1.
cli_assert_undetermined_only() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[^ ]*[[:space:]]+$2"; then
    fail "$1: $2 must not be classified preexisting ($(cli_baseline_lines))"
  else
    pass "$1: $2 not classified preexisting"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" \
      | grep -qE '^BASELINE_SUMMARY: preexisting=0 inherited=0 broken=0 undetermined=1$' \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "$1: summary undetermined=1 and exit 1"
  else
    fail "$1: expected summary undetermined=1 + exit 1; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
}

# Plan step 5 fail-closed classes: exit 77 at base (skip-at-base) and a home-.claude
# reference (home-claude-ref, detected by text and never executed) are undetermined.
run_cli_undetermined_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    fail "C3-skip-at-base: bin/run-tests-baseline not found (impl pending)"
    fail "C3-home-claude-ref: bin/run-tests-baseline not found (impl pending)"
    return
  fi
  local repo="$TMPROOT/repo-undet" t_skip="tests/bin/test-skip.sh" t_home="tests/bin/test-homeref.sh"
  local ran="$TMPROOT/homeref-executed"
  mk_fixture_repo "$repo" >/dev/null
  # Rewrite the homeref test at the base so any execution leaves a sentinel behind.
  git -C "$repo" checkout -q main
  printf '#!/usr/bin/env bash\ntouch "%s"\nls "$HOME/.claude" >/dev/null 2>&1\nexit 1\n' \
    "$(np "$ran")" > "$repo/$t_home"
  git -C "$repo" add "$t_home"
  git -C "$repo" commit -q -m "homeref sentinel"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main

  seed_failing "skp-$$" "$t_skip"
  rtb_cli_run "$(cli_case_cache skp)" "$repo" "skp-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_skip.*skip-at-base"; then
    pass "C3-skip-at-base: exit 77 at base classified undetermined skip-at-base"
  else
    fail "C3-skip-at-base: expected undetermined skip-at-base; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_undetermined_only "C3-skip-at-base" "$t_skip"
  cli_assert_not_completed "C3-skip-at-base" "skp-$$" "$t_skip"

  rm -f "$ran"
  seed_failing "hom-$$" "$t_home"
  rtb_cli_run "$(cli_case_cache hom)" "$repo" "hom-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_home.*home-claude-ref"; then
    pass "C3-home-claude-ref: \$HOME/.claude reference classified undetermined home-claude-ref"
  else
    fail "C3-home-claude-ref: expected undetermined home-claude-ref; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: [a-z-]+[[:space:]]+$t_home" && [ ! -e "$ran" ]; then
    pass "C3-home-claude-ref: the referencing test was never executed at base"
  else
    fail "C3-home-claude-ref: test body ran at base (sentinel $ran exists)"
  fi
  cli_assert_undetermined_only "C3-home-claude-ref" "$t_home"
  cli_assert_not_completed "C3-home-claude-ref" "hom-$$" "$t_home"
}

# Timeout/kill-shaped exit codes at base (124/137/142/143) are ambiguous — the test may have
# been killed rather than failed — so each must be undetermined ambiguous-exit-<rc>, never
# preexisting. The fixture test exits the code directly; the watchdog never fires.
run_cli_ambiguous_exit_cases() {
  local repo="$TMPROOT/repo-ambig" rc t
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  for rc in 124 137 142 143; do
    printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$repo/tests/bin/test-exit-$rc.sh"
    chmod +x "$repo/tests/bin/test-exit-$rc.sh"
  done
  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "ambiguous-exit tests at base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  for rc in 124 137 142 143; do
    t="tests/bin/test-exit-$rc.sh"
    seed_failing "amb$rc-$$" "$t"
    rtb_cli_run "$(cli_case_cache "amb$rc")" "$repo" "amb$rc-$$"
    if printf '%s\n' "$RTB_CLI_OUT" \
        | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+ambiguous-exit-$rc\$"; then
      pass "C3-ambiguous-exit-$rc: exit $rc at base classified undetermined ambiguous-exit-$rc"
    else
      fail "C3-ambiguous-exit-$rc: expected undetermined ambiguous-exit-$rc; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
    fi
    cli_assert_undetermined_only "C3-ambiguous-exit-$rc" "$t"
    cli_assert_not_completed "C3-ambiguous-exit-$rc" "amb$rc-$$" "$t"
  done
}

# A base checkout whose bin/lib/run-all-launch.sh cannot be sourced gives no verdict at all:
# rtb_exec_one returns 2 and the CLI must say undetermined exec-setup-failed, never preexisting.
run_cli_exec_setup_failed_cases() {
  local repo="$TMPROOT/repo-nolaunch" t="tests/bin/test-preexisting.sh"
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  mkdir -p "$repo/bin/lib"
  printf 'return 1\nrun_all_exec() { return 0; }\n' > "$repo/bin/lib/run-all-launch.sh"
  git -C "$repo" add bin/lib/run-all-launch.sh
  git -C "$repo" commit -q -m "unsourceable launcher at base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  seed_failing "nol-$$" "$t"
  rtb_cli_run "$(cli_case_cache nol)" "$repo" "nol-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+exec-setup-failed"; then
    pass "C3-exec-setup-failed: unsourceable base launcher classified undetermined exec-setup-failed"
  else
    fail "C3-exec-setup-failed: expected undetermined exec-setup-failed; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_undetermined_only "C3-exec-setup-failed" "$t"
  cli_assert_not_completed "C3-exec-setup-failed" "nol-$$" "$t"
}

# A same-merge-base `pass` ledger record is authoritative: the CLI classifies the test broken
# from the cache and never re-runs it. The base test fails and leaves a sentinel when executed,
# so a re-run would both flip the verdict to preexisting and be observable on disk.
run_cli_same_base_pass_cases() {
  local repo="$TMPROOT/repo-sbp" t="tests/bin/test-preexisting.sh" ran="$TMPROOT/sbp-executed"
  local cache base bc st basis
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$(np "$ran")" > "$repo/$t"
  git -C "$repo" add "$t"
  git -C "$repo" commit -q -m "sentinel-writing failing test at base"
  base="$(git -C "$repo" rev-parse main)"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main

  # Control: with an empty ledger the test really is re-run at base and fails there.
  seed_failing "sbp0-$$" "$t"
  rtb_cli_run "$(cli_case_cache sbp0)" "$repo" "sbp0-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t[[:space:]]+fails-at-base" \
    && [ -e "$ran" ]; then
    pass "C3-same-base-pass-control: without a ledger record the base re-run happens and fails"
  else
    fail "C3-same-base-pass-control: expected re-run + preexisting; rc=$RTB_CLI_RC ran=$([ -e "$ran" ] && echo y || echo n) ($(cli_baseline_lines))"
  fi

  rm -f "$ran"
  cache="$(cli_case_cache sbp)"
  ledger_call "$cache" "$repo" rtb_ledger_append "$base" "$t" pass >/dev/null 2>&1
  if [ "$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t" 2>/dev/null)" != "pass" ]; then
    fail "C3-same-base-pass: fixture error — seeded pass record not readable at $base"
    return
  fi
  seed_failing "sbp-$$" "$t"
  rtb_cli_run "$cache" "$repo" "sbp-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: broken[[:space:]]+$t[[:space:]]+ledger-same-base\$" \
    && printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE_SUMMARY: preexisting=0 inherited=0 broken=1 undetermined=0$'; then
    pass "C3-same-base-pass: cached same-base pass classified broken ledger-same-base"
  else
    fail "C3-same-base-pass: expected broken ledger-same-base; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  [ "$RTB_CLI_RC" -eq 1 ] && pass "C3-same-base-pass: exit 1" \
    || fail "C3-same-base-pass: expected exit 1, got $RTB_CLI_RC"
  if [ ! -e "$ran" ] && ! printf '%s\n' "$RTB_CLI_OUT" | grep -q 'base-run logs:'; then
    pass "C3-same-base-pass: no base re-run (no sentinel, no base-run logs)"
  else
    fail "C3-same-base-pass: the test was re-run at base despite the cached pass"
  fi
  st="$(read_step_field "sbp-$$" run_tests status)"
  basis="$(read_step_field "sbp-$$" run_tests completion_basis)"
  bc="$(read_step_field "sbp-$$" run_tests baseline_classification)"
  if [ "$st" = '"pending"' ] && [ "$basis" = "(absent)" ] \
    && printf '%s' "$bc" | grep -qF "$t" && printf '%s' "$bc" | grep -qF 'broken'; then
    pass "C3-same-base-pass: run_tests stays pending with broken recorded, no completion_basis"
  else
    fail "C3-same-base-pass: run_tests must stay pending; status=$st basis=$basis bc=$bc"
  fi
}

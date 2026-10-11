# shellcheck shell=bash
# shellcheck disable=SC2016,SC2088  # fixture text holds literal $HOME / ~ reference strings
# tests/bin/feature-2431-run-tests-baseline/cli-homeref.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, homeref, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# #2505: a home reference inside a whole-line comment must not stop the base re-run; any other
# reference, and every failure to decide, stays undetermined home-claude-ref. The pair partner of
# CH1 is C3-home-claude-ref in cli.sh (an executable reference), which stays unchanged.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

# ch_repo_begin <repo> — fixture repo with main checked out, ready for base-side test files.
ch_repo_begin() {
  mk_fixture_repo "$1" >/dev/null
  git -C "$1" checkout -q main
}

# ch_repo_end <repo> — commit the base-side files, return to feature with main merged in.
ch_repo_end() {
  git -C "$1" add tests/
  git -C "$1" commit -q -m "homeref fixtures at base"
  git -C "$1" checkout -q feature
  git -C "$1" merge -q --no-edit main
}

# ch_mk_test <repo> <rel-path> <sentinel> <body-line...> — a failing bash test that leaves a
# sentinel when executed, with the given extra lines between the shebang and the touch.
ch_mk_test() {
  local repo="$1" rel="$2" ran="$3"; shift 3
  mkdir -p "$(dirname "$repo/$rel")"
  printf '%s\n' '#!/usr/bin/env bash' "$@" "touch \"$(np "$ran")\"" 'exit 1' > "$repo/$rel"
  chmod +x "$repo/$rel"
}

# ch_run <label> <repo> <test> — seed the failing list and run the CLI (cache and sid per label).
ch_run() {
  seed_failing "$1-$$" "$3"
  rtb_cli_run "$(cli_case_cache "$1")" "$2" "$1-$$"
}

# cli_assert_completed <label> <sid> — the counterpart of cli_assert_not_completed: run_tests is
# complete, carries a completion_basis, and the CLI exited 0.
cli_assert_completed() {
  local st basis
  st="$(read_step_field "$2" run_tests status)"
  basis="$(read_step_field "$2" run_tests completion_basis)"
  if [ "$st" = '"complete"' ] && [ "$basis" != "(absent)" ] && [ "$RTB_CLI_RC" -eq 0 ]; then
    pass "$1: run_tests complete with a completion_basis, exit 0"
  else
    fail "$1: run_tests must complete; status=$st basis=$basis rc=$RTB_CLI_RC"
  fi
}

# ch_assert_preexisting <label> <test> <sentinel> — the comment-only verdict: the test really ran
# at base, failed there, and run_tests completed.
ch_assert_preexisting() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$2[[:space:]]+fails-at-base-exit-1"; then
    pass "$1: classified preexisting fails-at-base-exit-1"
  else
    fail "$1: expected preexisting fails-at-base-exit-1; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=0$'; then
    pass "$1: summary preexisting=1 undetermined=0"
  else
    fail "$1: summary mismatch ($(cli_baseline_lines))"
  fi
  if [ -e "$3" ]; then
    pass "$1: the test body was executed at base (sentinel present)"
  else
    fail "$1: the test body never ran at base (no sentinel)"
  fi
  cli_assert_completed "$1" "$4"
}

# ch_assert_undetermined <label> <test> <sentinel> <sid> — the fail-closed verdict: home-claude-ref,
# never executed, run_tests left pending.
ch_assert_undetermined() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$2[[:space:]]+home-claude-ref"; then
    pass "$1: classified undetermined home-claude-ref"
  else
    fail "$1: expected undetermined home-claude-ref; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if [ ! -e "$3" ]; then
    pass "$1: the test body was never executed at base"
  else
    fail "$1: the test body ran at base (sentinel $3 exists)"
  fi
  cli_assert_undetermined_only "$1" "$2"
  cli_assert_not_completed "$1" "$4" "$2"
}

# ch_lang_case <id> <rel-file-in-datadir> <expect: preexisting|undetermined> <content-line...>
# One fixture repo per language case, so the cases cannot influence each other.
ch_lang_case() {
  local id="$1" rel="$2" want="$3"; shift 3
  local repo="$TMPROOT/repo-$id" t="tests/bin/test-$id.sh" ran="$TMPROOT/$id-executed"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t" "$ran"
  mkdir -p "$repo/tests/bin/test-$id"
  printf '%s\n' "$@" > "$repo/tests/bin/test-$id/$rel"
  ch_repo_end "$repo"
  ch_run "$id" "$repo" "$t"
  if [ "$want" = preexisting ]; then
    ch_assert_preexisting "$id" "$t" "$ran" "$id-$$"
  else
    ch_assert_undetermined "$id" "$t" "$ran" "$id-$$"
  fi
}

run_cli_homeref_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    local id
    for id in CH1 CH3 CH4 CH5 CH6 CH7 CH8 CH9; do
      fail "$id: bin/run-tests-baseline not found (impl pending)"
    done
    return
  fi
  local repo t ran d

  # ---- CH1: comment-only references -> the test is re-run at base (pair of C3-home-claude-ref) ----
  repo="$TMPROOT/repo-ch1" t="tests/bin/test-homecomment.sh" ran="$TMPROOT/ch1-executed"
  ch_repo_begin "$repo"
  # shellcheck disable=SC2016  # literal reference text inside the fixture
  ch_mk_test "$repo" "$t" "$ran" '# ~/.claude is only mentioned here' '  # $HOME/.claude too'
  ch_repo_end "$repo"
  ch_run ch1 "$repo" "$t"
  ch_assert_preexisting "CH1" "$t" "$ran" "ch1-$$"

  # ---- CH3: comment reference plus an executable one -> undetermined ----
  repo="$TMPROOT/repo-ch3" t="tests/bin/test-homemixed.sh" ran="$TMPROOT/ch3-executed"
  ch_repo_begin "$repo"
  # shellcheck disable=SC2016
  ch_mk_test "$repo" "$t" "$ran" '# ~/.claude is only mentioned here' 'ls "$HOME/.claude" >/dev/null 2>&1'
  ch_repo_end "$repo"
  ch_run ch3 "$repo" "$t"
  ch_assert_undetermined "CH3" "$t" "$ran" "ch3-$$"

  # ---- CH4: end-of-line comment is not excluded (conservative) -> undetermined ----
  repo="$TMPROOT/repo-ch4" t="tests/bin/test-homeeol.sh" ran="$TMPROOT/ch4-executed"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t" "$ran" 'ls x >/dev/null 2>&1 # ~/.claude'
  ch_repo_end "$repo"
  ch_run ch4 "$repo" "$t"
  ch_assert_undetermined "CH4" "$t" "$ran" "ch4-$$"

  # ---- CH5: the reference sits in the data directory, comment-only (the feature-1733 shape) ----
  repo="$TMPROOT/repo-ch5" t="tests/bin/test-homedata.sh" ran="$TMPROOT/ch5-executed"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t" "$ran"
  mkdir -p "$repo/tests/bin/test-homedata"
  printf '%s\n' '# ~/.claude is only mentioned here' 'true' > "$repo/tests/bin/test-homedata/lib.sh"
  ch_repo_end "$repo"
  ch_run ch5 "$repo" "$t"
  ch_assert_preexisting "CH5" "$t" "$ran" "ch5-$$"

  # ---- CH6: per-language comment syntax inside the data directory ----
  ch_lang_case ch6a m.js preexisting '// ~/.claude'
  ch_lang_case ch6b m.js undetermined '# ~/.claude'
  ch_lang_case ch6c m.sh undetermined '// ~/.claude'
  ch_lang_case ch6d test_m.py preexisting '# ~/.claude'
  # shellcheck disable=SC2016
  ch_lang_case ch6e m.Tests.ps1 preexisting '# $env:USERPROFILE'

  # ---- CH7: unregistered extension gets no comment exclusion -> undetermined ----
  ch_lang_case ch7 notes.txt undetermined '# ~/.claude'

  # ---- CH8: awk fails (exit 3) -> fail-closed even for a comment-only test ----
  repo="$TMPROOT/repo-ch8" t="tests/bin/test-homeawk.sh" ran="$TMPROOT/ch8-executed"
  d="$TMPROOT/ch8-stub"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' "echo called >> \"$(np "$d")/awk.log\"" 'exit 3' > "$d/awk"
  chmod +x "$d/awk"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t" "$ran" '# ~/.claude is only mentioned here'
  ch_repo_end "$repo"
  PATH="$d:$PATH" ch_run ch8 "$repo" "$t"
  ch_assert_undetermined "CH8" "$t" "$ran" "ch8-$$"
  if [ -s "$d/awk.log" ]; then
    pass "CH8: the awk stub was reached by the classifier"
  else
    fail "CH8: the awk stub was never invoked (the verdict above proves nothing)"
  fi

  # ---- CH9: find lists only part of the data directory, then fails -> fail-closed ----
  repo="$TMPROOT/repo-ch9" t="tests/bin/test-homefind.sh" ran="$TMPROOT/ch9-executed"
  d="$TMPROOT/ch9-stub"
  mkdir -p "$d"
  # The stub intercepts only the helper's `find <dir> -type f`; any other find call passes through.
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'case " $* " in *" -type f "*) printf "%s\n" "$1/ok.sh"; exit 1 ;; esac' \
    "exec \"$(command -v find)\" \"\$@\"" > "$d/find"
  chmod +x "$d/find"
  ch_repo_begin "$repo"
  ch_mk_test "$repo" "$t" "$ran"
  mkdir -p "$repo/tests/bin/test-homefind"
  printf '%s\n' '# ~/.claude is only mentioned here' > "$repo/tests/bin/test-homefind/ok.sh"
  printf '%s\n' 'ls ~/.claude' > "$repo/tests/bin/test-homefind/bad.sh"
  ch_repo_end "$repo"
  PATH="$d:$PATH" ch_run ch9 "$repo" "$t"
  ch_assert_undetermined "CH9" "$t" "$ran" "ch9-$$"
}

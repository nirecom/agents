#!/usr/bin/env bash
# tests/tests/feature-2561-mutation-root-names/timeout-cases.sh — sourced by
# tests/tests/feature-2561-mutation-root-names.sh: the fixture and the case bodies for the
# probe's time limit (--test-timeout). Functions only; each case takes the limit in seconds.

# timeout_fixture — tests/unit/hang-test.sh waits about a minute once bin/tool.sh is rewritten
# (from the start with ROOT_NAMES_HANG=baseline), far past any limit a case passes. It records
# its own pid and the pid of a process it started in <tmp root>/hang.pids.
timeout_fixture() {
  put tests/unit/hang-test.sh <<'FIXTURE'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd /
if grep -q "@M@" "$here/bin/tool.sh" || [[ "${ROOT_NAMES_HANG:-}" == baseline ]]; then
  bash -c 'n=0; while [[ ! -e "$1" && "$n" -lt 300 ]]; do sleep 0.2; n=$((n + 1)); done' _ "$here/../stop" &
  printf '%s\n%s\n' "$$" "$!" >"$here/../hang.pids"
  wait
fi
exit 0
FIXTURE
}

# hang_survivors — how many of the recorded processes are still alive (a few seconds of grace).
hang_survivors() {
  local pid n=0 alive=1
  [[ -f "$TMP_ROOT/hang.pids" ]] || { printf 'no pid record'; return; }
  while [[ "$alive" -gt 0 && "$n" -lt 15 ]]; do
    alive=0
    while read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then alive=$((alive + 1)); fi
    done <"$TMP_ROOT/hang.pids"
    [[ "$alive" -eq 0 ]] || sleep 0.2
    n=$((n + 1))
  done
  printf '%s' "$alive"
}

timeout_case_mutant_over_the_limit() {
  local started="$SECONDS"
  rm -f "$TMP_ROOT/hang.pids"
  rows script-to-main bin/tool.sh tests/unit/hang-test.sh
  probe --test-timeout "$1"
  expect_eq "a row whose only test is over the limit exits 2" "$RC" "2"
  if [[ "$((SECONDS - started))" -lt 45 ]]; then pass "the probe ends at the limit, not with the test"; else fail "the probe ends at the limit, not with the test" "took $((SECONDS - started))s"; fi
  expect_has "the row is not run and names the stopped test" "$OUT" "NOT RUN	script-to-main	bin/tool.sh	layer=none	line 3; static=clean; timed out after ${1}s: tests/unit/hang-test.sh;"
  expect_has "a stopped test is not counted as a kill" "$OUT" "SUMMARY: KILLED-STATIC=0 KILLED-DYNAMIC=0 KILLED-CRASH=0 LIVE=0 NOT-RUN=1"
  expect_eq "the probe prints the row and the summary only" "$(printf '%s\n' "$OUT" | grep -c .)" "2"
  expect_eq "the target is byte-identical again" "$(git -C "$LK" hash-object bin/tool.sh)" "$TOOL_SUM"
  expect_eq "the tree is clean" "$(tree_state)" ""
  expect_eq "the work directory is removed" "$(leftovers)" "0"
  expect_eq "the test and the process it started are gone" "$(hang_survivors)" "0"
  rows script-to-main bin/tool.sh "tests/unit/hang-test.sh,tests/unit/tool-test.sh"
  probe --test-timeout "$1"
  expect_eq "a later test that checks the value still kills the row" "$RC" "0"
  expect_has "the killer is the test that finished" "$OUT" "KILLED-DYNAMIC	script-to-main	bin/tool.sh	layer=dynamic-test	line 3; static=clean; tests/unit/tool-test.sh (exit"
  rows script-to-main bin/tool.sh "tests/unit/weak-test.sh,tests/unit/hang-test.sh"
  probe --test-timeout "$1"
  expect_eq "a pass beside a stopped test is not a live row" "$RC" "2"
  expect_has "the row beside a pass still names the stopped test" "$OUT" "NOT RUN	script-to-main	bin/tool.sh	layer=none	line 3; static=clean; timed out after ${1}s: tests/unit/hang-test.sh;"
  expect_eq "the tree is clean after every row" "$(tree_state)$(leftovers)" "0"
  expect_eq "no stopped test is left running" "$(hang_survivors)" "0"
}

timeout_case_baseline_over_the_limit() {
  rm -f "$TMP_ROOT/hang.pids"
  rows script-to-main bin/tool.sh tests/unit/hang-test.sh
  export ROOT_NAMES_HANG=baseline
  probe --test-timeout "$1"
  unset ROOT_NAMES_HANG
  expect_eq "a test over the limit before the rewrite exits 2" "$RC" "2"
  expect_has "the test is named as timed out, not as green" "$OUT" "NOT RUN	script-to-main	bin/tool.sh	layer=none	line 3; static=clean; no dynamic test was launched green before the rewrite: tests/unit/hang-test.sh:timed-out"
  expect_eq "the tree is clean" "$(tree_state)$(leftovers)" "0"
  expect_eq "the stopped test is gone" "$(hang_survivors)" "0"
}

timeout_case_static_check_and_finder() {
  rows script-to-main bin/tool.sh tests/unit/tool-test.sh
  export ROOT_NAMES_HANG=static
  probe --test-timeout "$1"
  expect_eq "a static check over the limit leaves the dynamic tests to decide" "$RC" "0"
  expect_has "the static check is reported as unusable" "$OUT" "KILLED-DYNAMIC	script-to-main	bin/tool.sh	layer=dynamic-test	line 3; static=unusable(before="
  rows script-to-main bin/tool.sh ""
  export ROOT_NAMES_HANG=finder
  probe --test-timeout "$1"
  unset ROOT_NAMES_HANG
  expect_eq "a finder over the limit selects no test" "$RC" "2"
  expect_has "the row without a selected test is not run" "$OUT" "no dynamic test was launched green before the rewrite: (none selected)"
  expect_eq "the tree is clean" "$(tree_state)$(leftovers)" "0"
}

timeout_case_option_value() {
  local value
  rows script-to-main bin/tool.sh tests/unit/tool-test.sh
  for value in 0 -5 1.5 abc "" "3 4"; do
    probe --test-timeout "$value"
    expect_eq "limit '$value' is refused" "$RC" "3"
  done
  expect_has "the refusal names the option" "$OUT" "--test-timeout must be a positive whole number of seconds"
  probe --test-timeout
  expect_eq "a limit without a value is refused" "$RC" "3"
  probe --dry-run --test-timeout 0
  expect_eq "a bad limit is refused in a dry run too" "$RC" "3"
  expect_eq "no refusal changed the tree" "$(tree_state)$(leftovers)" "0"
}

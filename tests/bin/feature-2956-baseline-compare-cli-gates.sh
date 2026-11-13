#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-compare-cli-gates.sh
# Tests: bin/lib/run-tests-baseline-compare.sh, bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, cli, compare, fail-details, scope:issue-specific, pwsh-not-required, TL2
# #2956 S8 rtb_test_changed <B2> <rel> [<old>]: a change in the index, the work tree, an untracked
# file in the test's data dir, or the rename itself counts; an untracked file elsewhere does not.
# #2956 S3 bootstrap: a base whose tests/lib/harness.sh lacks the fail-details.tsv writer exits 5
# (two CLI runs, two base worktrees). Fixture and helpers: feature-2956-baseline-compare-cli/_lib.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2956-baseline-compare-cli/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2956-baseline-compare-cli/_lib.sh"

# tc_call <repo> <B2> <rel> [<old>] — rtb_test_changed in a child bash run in <repo>; returns its rc
# (0 changed, 1 unchanged; 98 a lib could not be sourced, 97 the registry did not load).
tc_call() {
  local repo="$1"; shift
  (cd "$repo" && export ROOT="$repo" && run_with_timeout 30 bash -c '. "$1" || exit 98; tlr_load || exit 97; . "$2" || exit 98; shift 2; rtb_test_changed "$@"' tc_call "$TLR_LIB" "$COMPARE_LIB" "$@")
}

# tc_expect <label> <want-rc> <repo> <B2> <rel> [<old>]
tc_expect() {
  local label="$1" want="$2" rc=0; shift 2
  tc_call "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$want" ] && pass "$label" || fail "$label: rtb_test_changed rc=$rc, want $want"
}

# bs_repo <repo> <harness-body> — main gains tests/lib/harness.sh holding <harness-body>.
bs_repo() {
  mk_fixture_repo "$1" >/dev/null || return 1
  git -C "$1" checkout -q main
  mkdir -p "$1/tests/lib"
  printf '%s\n' "$2" >"$1/tests/lib/harness.sh"
  git -C "$1" add tests/lib/harness.sh
  git -C "$1" commit -q -m "base harness"
  git -C "$1" checkout -q feature
  git -C "$1" merge -q --no-edit main
}

TC="$TMPROOT/repo-tc"
TC_B2="$(mk_fixture_repo "$TC")"
T="tests/bin/test-broken.sh"
TP="tests/bin/test-preexisting.sh"

case_begin "compare-test-changed-clean-and-index" "bin/lib/run-tests-baseline-compare.sh"
tc_expect "test-changed: an untouched test file is unchanged" 1 "$TC" "$TC_B2" "$T"
printf '# staged\n' >>"$TC/$T"
git -C "$TC" add "$T"
tc_expect "test-changed: a change staged in the index counts" 0 "$TC" "$TC_B2" "$T"
git -C "$TC" reset -q --hard
case_end

case_begin "compare-test-changed-work-tree" "bin/lib/run-tests-baseline-compare.sh"
printf '# unstaged\n' >>"$TC/$T"
tc_expect "test-changed: an unstaged work-tree change counts" 0 "$TC" "$TC_B2" "$T"
git -C "$TC" checkout -q -- "$T"
case_end

case_begin "compare-test-changed-untracked" "bin/lib/run-tests-baseline-compare.sh"
mkdir -p "$TC/tests/bin/test-broken"
printf 'data\n' >"$TC/tests/bin/test-broken/extra.txt"
tc_expect "test-changed: an untracked file in the test's data dir counts" 0 "$TC" "$TC_B2" "$T"
rm -rf "$TC/tests/bin/test-broken"
printf 'x\n' >"$TC/tests/bin/unrelated.txt"
tc_expect "test-changed: an untracked file outside the pathspec does not count" 1 "$TC" "$TC_B2" "$T"
rm -f "$TC/tests/bin/unrelated.txt"
case_end

case_begin "compare-test-changed-rename" "bin/lib/run-tests-baseline-compare.sh"
git -C "$TC" mv "$T" tests/bin/test-moved.sh
tc_expect "test-changed: the rename itself counts (via-rename old path)" 0 "$TC" "$TC_B2" tests/bin/test-moved.sh "$T"
case_end

case_begin "compare-bootstrap-exit-5" "bin/lib/run-tests-baseline-exec.sh"
bs_repo "$TMPROOT/repo-bs-old" 'pass() { echo "PASS: $1"; }'
seed_failing "bso-$$" "$TP"
rtb_cli_run "$(cli_case_cache bso)" "$TMPROOT/repo-bs-old" "bso-$$"
if [ "$RTB_CLI_RC" -eq 5 ] && ! printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE: preexisting'; then
  pass "bootstrap: a base harness without the fail-details.tsv writer exits 5, nothing preexisting"
else
  fail "bootstrap: expected exit 5 and no preexisting line; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
fi
case_end

case_begin "compare-bootstrap-control" "bin/lib/run-tests-baseline-exec.sh"
bs_repo "$TMPROOT/repo-bs-new" 'printf "%s\n" x >>"$RUN_ALL_RESULT_DIR/fail-details.tsv"'
seed_failing "bsn-$$" "$TP"
rtb_cli_run "$(cli_case_cache bsn)" "$TMPROOT/repo-bs-new" "bsn-$$"
if [ "$RTB_CLI_RC" -eq 0 ] && printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$TP"; then
  pass "bootstrap control: a base harness holding the writer is compared, preexisting, exit 0"
else
  fail "bootstrap control: expected preexisting and exit 0; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

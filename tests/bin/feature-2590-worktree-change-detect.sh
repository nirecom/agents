#!/usr/bin/env bash
# Tests: bin/lib/run-all-launch.sh, bin/lib/run-all-worktree-change-detect.sh
# Tags: scope:issue-specific, tl2, run-all, worktree-change-detection, fixture-isolation
#
# Worktree change detection (#2590): the launcher fingerprints the protected trees around each
# test and names the test whose interval saw a change. Fixtures: feature-2590-worktree-change-detect/setup.sh.

# TL3 gap: a full parallel run-all over the real suite is not exercised; only fixture tests are.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID
ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
TAB="$(printf '\t')"

. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2590-worktree-change-detect/setup.sh"
wcd_setup || { echo "FAIL: fixture setup"; exit 1; }

FX_TREE="$MAIN_CO"
KINDS_OUT="$(drive "$MAIN_CO" detect "$TMP_ROOT/kinds.log" "$FX/noop.sh" "$FX/tracked.sh" "$FX/content.sh" "$FX/head.sh" "$FX/index.sh" "$FX/config.sh")"

case_begin "each-change-kind-is-named" "bin/lib/run-all-worktree-change-detect.sh"
expect_eq "the detection functions exist" "$(printf '%s\n' "$KINDS_OUT" | grep -c '^MISSING:run_all_worktree' || true)" "0"
expect_eq "a changed tracked file is named" "$(changes "$KINDS_OUT" "main checkout" tracked.sh tracked)" "1"
expect_eq "a further edit of a dirty file is named" "$(changes "$KINDS_OUT" "main checkout" content.sh content)" "1"
expect_eq "a moved HEAD is named" "$(changes "$KINDS_OUT" "main checkout" head.sh head)" "1"
expect_eq "a changed staged object is named" "$(changes "$KINDS_OUT" "main checkout" index.sh index)" "1"
expect_eq "a changed core.hooksPath is named" "$(changes "$KINDS_OUT" "main checkout" config.sh config)" "1"
expect_eq "the report returns non-zero after a change" "$([[ "$(field "$KINDS_OUT" REPORT_RC)" =~ ^[1-9][0-9]*$ ]] && [[ "$(field "$KINDS_OUT" REPORT_RC)" != 127 ]] && echo nonzero)" "nonzero"
case_end

case_begin "a-pre-dirty-tree-without-change-reports-nothing" "bin/lib/run-all-worktree-change-detect.sh"
QUIET_OUT="$(drive "$MAIN_CO" detect "$TMP_ROOT/quiet.log" "$FX/noop.sh")"
expect_eq "the no-op test ran" "$(field "$QUIET_OUT" EXEC:noop.sh)" "0"
expect_eq "the pre-existing changes are not reported" "$(change_lines "$QUIET_OUT")" "0"
expect_eq "the noop test is not named in the kinds run either" "$(printf '%s\n' "$KINDS_OUT" | grep '^\[run-all\] worktree change: ' | grep -c 'noop.sh' || true)" "0"
expect_eq "the report returns 0" "$(field "$QUIET_OUT" REPORT_RC)" "0"
case_end

case_begin "main-and-checkout-collapse-to-one-tree" "bin/lib/run-all-worktree-change-detect.sh"
ONE_OUT="$(drive "$MAIN_CO" detect "$TMP_ROOT/one.log" "$FX/head.sh")"
expect_eq "one change in the shared tree gives one line" "$(change_lines "$ONE_OUT")" "1"
expect_eq "that line names the main checkout" "$(changes "$ONE_OUT" "main checkout" head.sh head)" "1"
case_end

case_begin "main-and-linked-checkout-are-both-protected" "bin/lib/run-all-worktree-change-detect.sh"
FX_TREE="$MAIN_CO"
TO_MAIN="$(drive "$LINKED_CO" detect "$TMP_ROOT/linked-a.log" "$FX/tracked.sh")"
expect_eq "a change in the main worktree is named from a linked checkout" "$(changes "$TO_MAIN" "main checkout" tracked.sh tracked)" "1"
FX_TREE="$LINKED_CO"
TO_LINKED="$(drive "$LINKED_CO" detect "$TMP_ROOT/linked-b.log" "$FX/tracked.sh")"
expect_eq "a change in the linked checkout itself is named" "$(changes "$TO_LINKED" "linked checkout" tracked.sh tracked)" "1"
case_end

case_begin "overlapping-intervals-name-both-candidates" "bin/lib/run-all-worktree-change-detect.sh"
FX_TREE="$MAIN_CO"
OVER_OUT="$(drive "$MAIN_CO" overlap "$TMP_ROOT/overlap.log" "$FX/slow.sh" "$FX/mutator.sh")"
expect_eq "the test that changed HEAD is named" "$(changes "$OVER_OUT" "main checkout" mutator.sh head)" "1"
expect_eq "the test running alongside it is named too" "$(changes "$OVER_OUT" "main checkout" slow.sh head)" "1"
expect_has "the report says the names are candidates" "$(printf '%s\n' "$OVER_OUT" | tr 'A-Z' 'a-z')" "candidate"
case_end

# many_dirty <n> — a checkout named "many <n>" with exactly n modified tracked files; prints its path.
many_dirty() {
  local d="$TMP_ROOT/many $1" i
  wcd_checkout "$d" >/dev/null || return 1
  mkdir -p "$d/many"
  for i in $(seq 1 "$1"); do printf '0\n' >"$d/many/f$i.txt"; done
  git -C "$d" -c core.autocrlf=false add many && git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m many
  for i in $(seq 1 "$1"); do printf '1\n' >"$d/many/f$i.txt"; done
  printf '%s' "$d"
}
# Edits an already-modified file: the status line stays " M", only the content differs.
printf '%s\n' 'printf "2\n" >"$FX_TREE/many/f1.txt"' >"$FX/content-many.sh"

case_begin "content-comparison-holds-at-500-files" "bin/lib/run-all-worktree-change-detect.sh"
FX_TREE="$(many_dirty 500)" || fail "500-file fixture checkout"
AT500_OUT="$(drive "$FX_TREE" detect "$TMP_ROOT/at500.log" "$FX/content-many.sh")"
expect_eq "the 500-file test ran" "$(field "$AT500_OUT" EXEC:content-many.sh)" "0"
expect_eq "a content-only edit at 500 files is named" "$(changes "$AT500_OUT" "many 500" content-many.sh content)" "1"
expect_eq "nothing is skipped at 500 files" "$(printf '%s\n' "$AT500_OUT" | tr 'A-Z' 'a-z' | grep -c 'content comparison skipped' || true)" "0"
AT500_RC="$(field "$AT500_OUT" REPORT_RC)"
expect_eq "the report returns non-zero after the 500-file change" "$([[ "$AT500_RC" =~ ^[1-9][0-9]*$ && "$AT500_RC" != 127 ]] && echo nonzero)" "nonzero"
case_end

# The plan sets no exit code for a skipped comparison (only the report line), so none is asserted.
case_begin "content-comparison-is-skipped-above-500-files" "bin/lib/run-all-worktree-change-detect.sh"
FX_TREE="$(many_dirty 501)" || fail "501-file fixture checkout"
AT501_OUT="$(drive "$FX_TREE" detect "$TMP_ROOT/at501.log" "$FX/content-many.sh")"
expect_eq "the 501-file test ran" "$(field "$AT501_OUT" EXEC:content-many.sh)" "0"
expect_has "the report says the content comparison was skipped" "$(printf '%s\n' "$AT501_OUT" | tr 'A-Z' 'a-z')" "content comparison skipped"
expect_eq "no content change is claimed at 501 files" "$(changes "$AT501_OUT" "many 501" content-many.sh content)" "0"
case_end

FX_TREE="$MAIN_CO"
FULL_OUT="$(drive "$MAIN_CO" full "$TMP_ROOT/work" "$FX/reporter.sh")"

case_begin "the-launcher-pins-run-root-guard-and-temp" "bin/lib/run-all-launch.sh"
expect_eq "run_all_pin_command_guard exists" "$(printf '%s\n' "$FULL_OUT" | grep -c '^MISSING:run_all_pin_command_guard' || true)" "0"
expect_eq "TEST_RUN_ROOT is the work dir" "$(nlow "$(field "$FULL_OUT" RUN_ROOT)")" "$(nlow "$TMP_ROOT/work")"
expect_eq "the guard instance sits in the work dir" "$(nlow "$(field "$FULL_OUT" GUARD)")" "$(nlow "$TMP_ROOT/work")/command-guard"
expect_eq "TMPDIR is pinned under the work dir" "$(nlow "$(field "$FULL_OUT" TMPDIR)")" "$(nlow "$TMP_ROOT/work")/tmp"
expect_has "the guard bin is first on PATH" "$(field "$FULL_OUT" PATH1 | tr 'A-Z\\' 'a-z/')" "/command-guard/bin"
case_end

case_begin "the-combined-hit-report-fails-the-run" "bin/lib/run-all-launch.sh"
expect_eq "run_all_hit_report exists" "$(printf '%s\n' "$FULL_OUT" | grep -c '^MISSING:run_all_hit_report' || true)" "0"
expect_eq "the reporter test itself passed" "$(field "$FULL_OUT" EXEC:reporter.sh)" "0"
FULL_RC="$(field "$FULL_OUT" REPORT_RC)"
expect_eq "the combined report is non-zero" "$([[ "$FULL_RC" =~ ^[1-9][0-9]*$ && "$FULL_RC" != 127 ]] && echo nonzero)" "nonzero"
expect_has "the root decoy report is still included" "$FULL_OUT" "root decoy hit: main/decoy/own.js$TAB"
expect_eq "the rejected git write is a command guard line" "$(printf '%s\n' "$FULL_OUT" | grep -c "^\[run-all\] command guard hit: git$TAB[^$TAB]*reporter.sh$TAB." || true)" "1"
expect_eq "the tracked change is a worktree change line" "$(changes "$FULL_OUT" "main checkout" reporter.sh tracked)" "1"
expect_ne "the guard refused the commit outside the run root" "$(git -C "$MAIN_CO" log -1 --format=%s)" "guarded"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# tests/bin/feature-2688-branch-cache.sh
# Tests: bin/lib/run-tests-baseline-branch.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, branch-rerun, cache, input-version, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:runtime-limit, budget
# dup-group-keep: together with feature-2688-branch-rerun.sh (same Tests:), the real CLI runs overlap and exceed the 120 s limit.
# To balance run time, the budget-slice cases (zero and boundary) are placed here too.
# #2688 T2 - cache for the branch standalone re-run. Results are kept in branch.v1.*.seg keyed by input_version,
# and a second run with the same input_version does not re-run. A changed working tree re-runs, and when input_version
# cannot be resolved (merge base unknown) it re-runs every time. A fails-alone result is also reused (proceeding to the base stage),
# and a broken or old-format segment is not used but falls back to a re-run (fail-closed).
# TL3 gap: the time to compute input_version in a real worktree is out of scope.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"

case_begin "zero-budget-slice-skips-the-rerun" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/bud"; mk_repo "$R" 0; S="br-bud-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S" RTB_BUDGET_TOTAL=50
ck "budget: exit 8 (re-run requested)" 8 "$RTB_RC"
absent "budget: no branch re-run on a zero slice" "$R.marks/branch"
absent "budget: no base run on a zero slice" "$R.marks/base"
has_line "budget: budget-exhausted line" "budget-exhausted"
ck "budget: run_tests stays pending" "pending" "$(field "$S" status)"
case_end

# Budget boundary: the branch stage passes elapsed = SECONDS + 150 (RTB_BRANCH_BASE_RESERVE) to the budget clamp, so
# remaining = total - 45 (SAFETY) - 2 (KILL_GRACE) - 150 - SECONDS, and the slice is 0 when remaining < 30 (MIN_SLICE).
# slice>0 needs total >= 227 + SECONDS. 197 = 227 - 30 is the lower side: with the reserve the slice is always 0, but if the
# reserve fell back to 0 the remaining would be 150 - SECONDS >= 30 and the branch copy would run (a reserve regression is caught).
# The base stage carries no reserve, so at 197 it still runs after the branch stage skips.
# 257 = 227 + 30 s of SECONDS jitter margin (the upper side).
case_begin "budget-boundary-197-skips-the-rerun" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/bud197"; mk_repo "$R" 0; S="br-bud197-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S" RTB_BUDGET_TOTAL=197
ck "bud197: exit 0 (the base stage has no reserve and still fits)" 0 "$RTB_RC"
absent "bud197: no branch re-run on a zero slice" "$R.marks/branch"
lacks_line "bud197: not classified flaky" "flaky-timeout-on-branch"
has_line "bud197: goes on to base (preexisting)" "BASELINE: preexisting tests/bin/t.sh"
case_end

case_begin "budget-boundary-257-still-reruns" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/bud257"; mk_repo "$R" 0; S="br-bud257-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S" RTB_BUDGET_TOTAL=257
ck "bud257: exit 0 (flaky recorded)" 0 "$RTB_RC"
present "bud257: the branch copy ran on a positive slice" "$R.marks/branch"
has_line "bud257: flaky line" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
lacks_line "bud257: no budget-exhausted line" "budget-exhausted"
case_end

case_begin "same-input-version-reuses-the-rerun" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/cache1"; mk_repo "$R" 0; mkdir -p "$R.cache"
seed "c1a-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c1a-$$"
ck "cache: first run records flaky" 0 "$RTB_RC"
present "cache: first run re-ran the branch copy" "$R.marks/branch"
rm -f "$R.marks/branch"
seed "c1b-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c1b-$$"
ck "cache: second run exit 0" 0 "$RTB_RC"
absent "cache: second run did not re-run (same input_version)" "$R.marks/branch"
has_line "cache: second run still flaky" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
ls "$R.cache"/branch.v1.*.seg >/dev/null 2>&1 && pass "cache: a branch.v1 segment was written" \
  || fail "cache: a branch.v1 segment was written" "$(ls -A "$R.cache" 2>&1)"
case_end

case_begin "changed-input-version-reruns" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/cache2"; mk_repo "$R" 0; mkdir -p "$R.cache"
seed "c2a-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c2a-$$"
rm -f "$R.marks/branch"
printf 'head changed\n' > "$R/head.txt"
seed "c2b-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c2b-$$"
present "cache: an uncommitted change re-runs the branch copy" "$R.marks/branch"
case_end

case_begin "null-input-version-always-reruns" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/cache3"; mk_repo "$R" 0; mkdir -p "$R.cache"
seed "c3a-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c3a-$$" DEFAULT_BRANCHES=nonexistent-2688
present "null input_version: first run re-runs" "$R.marks/branch"
rm -f "$R.marks/branch"
seed "c3b-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c3b-$$" DEFAULT_BRANCHES=nonexistent-2688
present "null input_version: second run re-runs too (no cache key)" "$R.marks/branch"
case_end

case_begin "cached-fails-alone-goes-on-to-base" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/cache4"; mk_repo "$R" 1; mkdir -p "$R.cache"
seed "c4a-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c4a-$$"
present "fails-alone: first run re-ran the branch copy" "$R.marks/branch"
rm -f "$R.marks/branch"
seed "c4b-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c4b-$$"
ck "fails-alone: second run exit 0 (preexisting)" 0 "$RTB_RC"
absent "fails-alone: cached result skips the branch re-run" "$R.marks/branch"
has_line "fails-alone: still goes on to base (preexisting)" "BASELINE: preexisting tests/bin/t.sh"
lacks_line "fails-alone: cached fails-alone is not read as a pass" "flaky-timeout-on-branch"
case_end

# A broken or old-format segment is not used and falls back to a standalone re-run (fail-closed). Create one valid segment,
# then place only a single file transformed from it by seg_variant and re-run.
case_begin "broken-or-old-segment-falls-back-to-rerun" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/cache5"; mk_repo "$R" 0; mkdir -p "$R.cache"
seed "c5a-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "c5a-$$"
cat "$R.cache"/branch.v1.*.seg > "$R.saved" 2>/dev/null || : > "$R.saved"
[ -s "$R.saved" ] && pass "broken-segment: precondition — the first run wrote a branch.v1 segment" \
  || fail "broken-segment: precondition — the first run wrote a branch.v1 segment" "$(ls -A "$R.cache" 2>&1)"
for variant in garbage old-tag old-layout unknown-result; do
  [ -s "$R.saved" ] || break
  rm -f "$R.cache"/branch.v1.*.seg "$R.marks/branch"
  seg_variant "$variant" "$R.saved" "$R.cache/branch.v1.fixture-0-0.seg" || fail "$variant: fixture error"
  seed "c5-$variant-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh
  rtb "$R.cache" "$R" "c5-$variant-$$"
  present "$variant: the segment is not trusted, the branch copy re-runs" "$R.marks/branch"
  has_line "$variant: the re-run still classifies flaky" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
done
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

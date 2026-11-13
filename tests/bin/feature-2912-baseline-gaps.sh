#!/usr/bin/env bash
# tests/bin/feature-2912-baseline-gaps.sh
# Tests: bin/lib/run-tests-baseline-branch.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, branch-rerun, cache, merge-base, detail, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:time-hard-limit
# dup-group-keep: the two feature-2688-branch-*.sh files in this group already run near the 150 s HARD limit.
# #2912 bash-side gaps: branch solo exit 77/137/143 is never a pass and its b2 cache row keeps the reason (#2956 S7);
# a branch that decides every test needs no merge base; the branch-side detail column. The post-base class of the
# 77/137/143 rows (#2956 S8 table 2) is feature-2956-baseline-ledger-paths.sh's.
# TL3 gap: a real /run-tests run recording failing_test_exits is substituted by seed.

set -uo pipefail

# Pin once at top level for the isolation checker; _lib.sh re-points both into its own temp root.
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-2912-gaps-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-2912-gaps-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"

# has_exact <desc> <line> - RTB_OUT carries <line> as a whole line.
has_exact() {
  if printf '%s\n' "$RTB_OUT" | grep -Fxq -- "$2"; then pass "$1"; else fail "$1" "no line [$2] in: $RTB_OUT"; fi
}
# cache_row <desc> <cache-dir> <rel> <result> - a branch.v2 row: b2, 7 columns, this path and result.
cache_row() {
  local f found=0
  for f in "$2"/branch.v2.*.seg; do
    [ -f "$f" ] || continue
    if awk -F '\t' -v REL="$3" -v RES="$4" 'NF == 7 && $1 == "b2" && $4 == REL && $5 == RES { hit = 1 } END { exit hit ? 0 : 1 }' "$f"; then
      found=1
    fi
  done
  if [ "$found" = 1 ]; then pass "$1"; else fail "$1" "no b2 row [$3 $4] in: $(cat "$2"/branch.* 2>/dev/null | tr '\t' ' ')"; fi
}

# Branch exits 77 / 137 / 143 for t / u / v; every base copy exits 1. All three are seeded as exit 124,
# so reading any of them as a solo pass would print flaky-timeout-on-branch.
case_begin "branch-rerun-exit-77-137-143-is-not-a-pass" "bin/lib/run-tests-baseline-branch.sh"
RK="$TMPROOT/kill"; mk_repo "$RK" 77; add_test "$RK" u.sh 1 137; add_test "$RK" v.sh 1 143; mkdir -p "$RK.cache"
EX='{"tests/bin/t.sh":124,"tests/bin/u.sh":124,"tests/bin/v.sh":124}'
seed "k1-$$" "$EX" tests/bin/t.sh tests/bin/u.sh tests/bin/v.sh
rtb "$RK.cache" "$RK" "k1-$$"
present "kill: t (exit 77) ran alone on the branch" "$RK.marks/branch"
present "kill: u (exit 137) ran alone on the branch" "$RK.marks/branch-u"
present "kill: v (exit 143) ran alone on the branch" "$RK.marks/branch-v"
lacks_line "kill: no exit is read as a solo pass after 124" "flaky-timeout-on-branch"
lacks_line "kill: no exit is read as a solo pass" "passes-alone-on-branch"
case_end

case_begin "branch-cache-keeps-the-inconclusive-reason" "bin/lib/run-tests-baseline-branch.sh"
cache_row "reason: exit 77 is cached as inconclusive:skip" "$RK.cache" tests/bin/t.sh "inconclusive:skip"
cache_row "reason: exit 137 is cached as inconclusive:kill-137" "$RK.cache" tests/bin/u.sh "inconclusive:kill-137"
cache_row "reason: exit 143 is cached as inconclusive:kill-143" "$RK.cache" tests/bin/v.sh "inconclusive:kill-143"
rm -f "$RK.marks/branch" "$RK.marks/branch-u" "$RK.marks/branch-v"
seed "k2-$$" "$EX" tests/bin/t.sh tests/bin/u.sh tests/bin/v.sh
rtb "$RK.cache" "$RK" "k2-$$"
absent "reuse: the cached inconclusive:skip is reused (t does not re-run)" "$RK.marks/branch"
absent "reuse: the cached inconclusive:kill-137 is reused (u does not re-run)" "$RK.marks/branch-u"
absent "reuse: the cached inconclusive:kill-143 is reused (v does not re-run)" "$RK.marks/branch-v"
lacks_line "reuse: a cached inconclusive is not read as a pass" "flaky-timeout-on-branch"
case_end

# No trustworthy merge base: main is deleted, so resolve-merge-base falls back to HEAD~1 (FALLBACK, die 4).
# t / u / v pass alone on the branch; x fails alone.
RN="$TMPROOT/nobase"; mk_repo "$RN" 0; add_test "$RN" u.sh 1 0; add_test "$RN" v.sh 1 0; add_test "$RN" x.sh 1 1
git -C "$RN" branch -q -D main; mkdir -p "$RN.cache"

case_begin "branch-decides-everything-without-a-merge-base" "bin/run-tests-baseline"
seed "nb1-$$" '{"tests/bin/t.sh":124,"tests/bin/u.sh":1}' tests/bin/t.sh tests/bin/u.sh tests/bin/v.sh
rtb "$RN.cache" "$RN" "nb1-$$"
ck "nobase: exit 1 (passes-alone is pending), not 4 (merge base)" 1 "$RTB_RC"
lacks_line "nobase: the merge base is never asked for" "merge base is"
absent "nobase: no base copy of t ran" "$RN.marks/base"
absent "nobase: no base copy of u ran" "$RN.marks/base-u"
absent "nobase: no base copy of v ran" "$RN.marks/base-v"
case_end

case_begin "branch-class-detail-column" "bin/run-tests-baseline"
has_exact "detail: 124 then a solo pass" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh exit-124-then-pass"
has_exact "detail: 1 then a solo pass" "BASELINE: passes-alone-on-branch tests/bin/u.sh exit-1-then-pass"
has_exact "detail: no recorded exit then a solo pass" "BASELINE: passes-alone-on-branch tests/bin/v.sh exit-unknown-then-pass"
has_exact "detail: summary carries the #2956 counters" \
  "BASELINE_SUMMARY: preexisting=0 inherited=0 broken=0 undetermined=3 file_verdict=0 new_on_branch=0"
case_end

case_begin "branch-leftover-still-needs-the-merge-base" "bin/run-tests-baseline"
seed "nb2-$$" '{"tests/bin/t.sh":124}' tests/bin/t.sh tests/bin/x.sh
rtb "$RN.cache" "$RN" "nb2-$$"
ck "control: a solo failure needs the base, which does not resolve (exit 4)" 4 "$RTB_RC"
has_line "control: the merge base is named as the reason" "merge base is"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

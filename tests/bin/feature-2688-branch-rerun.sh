#!/usr/bin/env bash
# tests/bin/feature-2688-branch-rerun.sh
# Tests: bin/lib/run-tests-baseline-branch.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, branch-rerun, flaky, budget, cache, input-version, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:runtime-limit, dup-group-keep:time-hard-limit
# dup-group-keep: together with feature-2688-branch-cache.sh (same Tests:), the real CLI runs overlap and exceed the 120 s limit.
# #2688 T2 - standalone re-run on the branch side. exit 124 + standalone pass is flaky-timeout-on-branch (auto-accepted),
# any other exit + standalone pass is passes-alone-on-branch (pending), and a standalone failure proceeds to the next stage (base).
# The budget slice (including boundaries) and cache (input_version) cases are in feature-2688-branch-cache.sh.
# The timeout-side cases: flaky in feature-2956-baseline-branch-kill-skip.sh, unjudgeable re-runs in feature-2956-baseline-branch-paths.sh.
# TL3 gap: the path where a real /run-tests records failing_test_exits is substituted by seed.

set -uo pipefail

# Pin once at top level for the isolation checker; _lib.sh re-points both into its own temp root.
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-2688-rerun-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-2688-rerun-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"

case_begin "branch-lib-present" "bin/lib/run-tests-baseline-branch.sh"
[ -f "$BRANCH_LIB" ] && pass "run-tests-baseline-branch.sh exists" \
  || fail "run-tests-baseline-branch.sh exists" "missing (not implemented yet)"
case_end

case_begin "other-exit-then-pass-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/j2"; mk_repo "$R" 0; S="br-j2-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":1}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j2: exit 1 (pending)" 1 "$RTB_RC"
has_line "j2: passes-alone line" "BASELINE: passes-alone-on-branch tests/bin/t.sh"
present "j2: the branch copy ran alone" "$R.marks/branch"
absent "j2: the base copy never ran" "$R.marks/base"
ck "j2: run_tests stays pending" "pending" "$(field "$S" status)"
ck "j2: no completion_basis" "(absent)" "$(field "$S" completion_basis)"
case_end

case_begin "unknown-exit-then-pass-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/j3"; mk_repo "$R" 0; S="br-j3-$$"; mkdir -p "$R.cache"
seed "$S" none tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j3: exit 1 (pending)" 1 "$RTB_RC"
has_line "j3: passes-alone line" "BASELINE: passes-alone-on-branch tests/bin/t.sh"
present "j3: the branch copy ran alone" "$R.marks/branch"
ck "j3: run_tests stays pending" "pending" "$(field "$S" status)"
case_end

case_begin "fails-alone-goes-on-to-base" "bin/run-tests-baseline"
R="$TMPROOT/j4"; mk_repo "$R" 1; S="br-j4-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
# #2956 S8 table 1: the branch copy differs from base, so the base failure is a file verdict (auto), not proof.
ck "j4: exit 0 (file verdict at base, auto)" 0 "$RTB_RC"
present "j4: the branch copy ran alone first" "$R.marks/branch"
present "j4: then the base copy ran" "$R.marks/base"
has_line "j4: file-verdict line" "BASELINE: file-verdict-preexisting tests/bin/t.sh test-file-changed"
lacks_line "j4: no flaky line" "flaky-timeout-on-branch"
ck "j4: completion_basis" "baseline-auto-accepted" "$(field "$S" completion_basis)"
case_end

# With multiple failing tests, each is judged individually. If even one is pending, the whole result is pending (exit 1).
case_begin "mixed-flaky-and-passes-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/mix1"; mk_repo "$R" 0; add_test "$R" u.sh 1 0; S="br-mix1-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124,"tests/bin/u.sh":1}' tests/bin/t.sh tests/bin/u.sh
rtb "$R.cache" "$R" "$S"
ck "mix1: exit 1 (one pending wins)" 1 "$RTB_RC"
has_line "mix1: t is flaky" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
has_line "mix1: u passes alone" "BASELINE: passes-alone-on-branch tests/bin/u.sh"
lacks_line "mix1: u is not flaky" "flaky-timeout-on-branch tests/bin/u.sh"
present "mix1: t ran alone" "$R.marks/branch"
present "mix1: u ran alone" "$R.marks/branch-u"
ck "mix1: run_tests stays pending" "pending" "$(field "$S" status)"
ck "mix1: no completion_basis" "(absent)" "$(field "$S" completion_basis)"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

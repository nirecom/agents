#!/usr/bin/env bash
# g-real-node-tests.sh — the repo's own Node tests in tests/hooks are discovered and run by the real runner (#2501).
# Tests: tests/run-all.sh, bin/lib/run-all-launch.sh, bin/lib/test-wrappers/node.js, hooks/lib/test-language-registry.json
# Tags: tests, bin, run-all, report, node, registry, scope:issue-specific

# WHY: every other member runs generated fixtures, so none of them notices when the js entry stops
# covering the checked-in Node tests. Here the worktree's own runner and registry meet the three
# real tests/hooks/feature-2326-*.js files: --all must list them, and running them must yield one
# file verdict each and a contract that counts all three.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

fx_init "g-real-node-tests"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report
# This member already runs inside a leased run; the inner runner must not wait for a second lane.
export TEST_LANES=off

REAL_RUNNER="$FX_REPO_ROOT/tests/run-all.sh"
REAL_NODE_TESTS="feature-2326-resolve-rtk-bin.js feature-2326-rtk-guard-audit.js feature-2326-rtk-rewrite.js"

# real_exec <timeout> <out> <err> [runner-args] — the worktree runner over the worktree's tests/.
real_exec() {
    local to="$1" out="$2" err="$3" rc=0; shift 3
    # shellcheck disable=SC2046  # word-splitting into env argv items is the point (see fx_exec)
    run_with_timeout "$to" env $(fx_control_args) "RUN_ALL_CACHE_DIR=$FX_CACHE_DIR" \
        "RUN_ALL_REGISTRY_LIB=$FX_REPO_ROOT/bin/lib/test-language-registry.sh" \
        bash "$REAL_RUNNER" "$@" >"$out" 2>"$err" || rc=$?
    return "$rc"
}

# --- discovery: --all lists the three files ------------------------------------
PL="$FX_TMP_ROOT/plan.out"
real_exec 240 "$PL" "$FX_TMP_ROOT/plan.err" -j 1 --print-plan --all; PLRC=$?

case_begin "all-discovers-the-real-node-tests" "tests/run-all.sh"
[ "$PLRC" -eq 0 ]
fx_check $? "G1. --print-plan --all exits 0 (rc=$PLRC)"
for t in $REAL_NODE_TESTS; do
    [ -f "$FX_REPO_ROOT/tests/hooks/$t" ]
    fx_check $? "G2. the checked-in test exists: tests/hooks/$t"
    [ "$(awk -F'\t' -v s="/tests/hooks/$t" '$1 == "plan" && substr($4, length($4) - length(s) + 1) == s' "$PL" | grep -c '')" = "1" ]
    fx_check $? "G3. --all plans tests/hooks/$t exactly once"
done
case_end

# --- execution: one verdict per file, all three in the contract ----------------
RO="$FX_TMP_ROOT/run.out"
RE="$FX_TMP_ROOT/run.err"
run_args=()
for t in $REAL_NODE_TESTS; do run_args+=("$FX_REPO_ROOT/tests/hooks/$t"); done
real_exec 280 "$RO" "$RE" -j 3 "${run_args[@]}"; RRC=$?

case_begin "real-node-tests-yield-three-file-verdicts" "bin/lib/run-all-launch.sh"
[ "$RRC" -eq 0 ]
fx_check $? "G4. the three real Node tests leave the runner at exit 0 (rc=$RRC)"
for t in $REAL_NODE_TESTS; do
    # These files only ever exit 0 or 1, so a SKIP would mean the file was never run.
    [ "$(grep -cE "^(PASS|SKIP): .*/tests/hooks/$t\$|^FAIL: .*/tests/hooks/$t \\(exit [0-9]+\\)\$" "$RO")" = "1" ] &&
        grep -qE "^PASS: .*/tests/hooks/$t\$" "$RO"
    fx_check $? "G5. exactly one file verdict, and it is PASS, for tests/hooks/$t"
done
! grep -qE '^(UNSUPPORTED|UNRUNNABLE|TIMEOUT): ' "$RO"
fx_check $? "G6. no file is reported UNSUPPORTED, UNRUNNABLE or TIMEOUT"
rest="$(rr_contract_rest "$RO")"
[ "$(fx_count_contract "$RO")" = "1" ] && [[ "$rest" == *" FAIL=0 "* ]] && [[ "$rest" == *" EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0" ]]
fx_check $? "G7. one contract line: FAIL=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0 (got <<$rest>>)"
pass_n="$(fx_contract_field "$RO" PASS)"; skip_n="$(fx_contract_field "$RO" SKIP)"
[ "${pass_n:-}" = "3" ] && [ "${skip_n:-}" = "0" ]
fx_check $? "G8. the contract counts all three as passed: PASS=3 SKIP=0 (PASS=${pass_n:-?} SKIP=${skip_n:-?})"
case_end

[ "$FX_ERRORS" -eq 0 ] || { fx_show_tail "$PL" 10; fx_show_tail "$RO" 30; fx_show_tail "$RE" 20; }
fx_finish

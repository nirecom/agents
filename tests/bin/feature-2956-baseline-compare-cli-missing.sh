#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-compare-cli-missing.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, compare, fail-details, scope:issue-specific, pwsh-not-required, TL2, rename, ledger
# #2956 S4/S8 in one CLI run (one base worktree): records on one side only, in both directions,
# no records on either side, a path renamed on the branch mapped back to its base name, and lines
# equal only after normalization (line number, duration).
# Fixture and helpers: feature-2956-baseline-compare-cli/_lib.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2956-baseline-compare-cli/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2956-baseline-compare-cli/_lib.sh"

cmp_run missing basemiss brmiss norec ren same

case_begin "compare-cli-base-missing" "bin/run-tests-baseline"
cmp_expect "base-missing: records only on the branch are case-records-missing-at-base" "new-case-failure-on-branch tests/bin/t-basemiss\.sh case-records-missing-at-base"
case_end

case_begin "compare-cli-branch-missing" "bin/run-tests-baseline"
cmp_expect "branch-missing: records only at base are case-records-missing-on-branch" "new-case-failure-on-branch tests/bin/t-brmiss\.sh case-records-missing-on-branch"
case_end

case_begin "compare-cli-no-records" "bin/run-tests-baseline"
cmp_expect "no-records: no record on either side is file-verdict-preexisting no-case-records" "file-verdict-preexisting tests/bin/t-norec\.sh no-case-records"
case_end

case_begin "compare-cli-rename-map" "bin/run-tests-baseline"
cmp_expect_pre "rename: a path renamed on the branch maps back to its base name, preexisting" ren
case_end

case_begin "compare-cli-normalized-equal" "bin/run-tests-baseline"
cmp_expect_pre "normalize: lines equal after line number and duration normalization are preexisting" same
cmp_expect_summary "summary: preexisting=2 file_verdict=1 new_on_branch=2, exit 1" 1 2 1 2
case_end

# #3015: a renamed test's base ledger row is reused on the next run; two CLI runs on their own repo and cache.
# shellcheck source=./feature-2956-baseline-compare-cli/rename-reuse.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2956-baseline-compare-cli/rename-reuse.sh"
case_begin "renamed-test-base-row-is-reused-on-the-next-run" "bin/run-tests-baseline"
run_compare_cli_rename_reuse_cases
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

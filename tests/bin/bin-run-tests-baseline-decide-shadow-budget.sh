#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-shadow-budget.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# #3068 in-run shadow (b) and the budget: checks that at SECONDS=530 the budget decisions are the same with the shadow on and off,
# and that at SECONDS=590, with under 25 seconds left, the shadow does not run and leaves skipped=budget-short.
# Case bodies: bin-run-tests-baseline-decide-shadow-isolation/{budget,_lib}.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_isolate "$(make_tmp)"
SI_SUB="$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-run-tests-baseline-decide-shadow-isolation"
# shellcheck source=./bin-run-tests-baseline-decide-shadow-isolation/_lib.sh
. "$SI_SUB/_lib.sh"
# shellcheck source=./bin-run-tests-baseline-decide-shadow-isolation/budget.sh
. "$SI_SUB/budget.sh"

case_begin "budget-verdicts-same-shadow-on-and-off" "bin/run-tests-baseline"
si_case_budget_same
case_end

case_begin "budget-short-skips-shadow" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_budget_short
case_end

case_begin "pre-cap-work-runs-under-cap" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_pre_cap_work_capped
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

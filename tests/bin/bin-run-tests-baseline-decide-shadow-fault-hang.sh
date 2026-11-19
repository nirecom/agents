#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-shadow-fault-hang.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# #3068 in-run shadow (b): checks that even when the shadow hangs via the seam RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=hang,
# the 10-second watchdog cuts it off, the CLI's exit, stdout and state keep the current code's values
# (variant expect), and SUMMARY keeps skipped=timed-out.
# TL3 gap: the real time of the 10-second watchdog (Windows Git Bash and Linux) is measured in the evidence step.
# Case bodies: bin-run-tests-baseline-decide-shadow-isolation/{fault,_lib}.sh.

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
# shellcheck source=./bin-run-tests-baseline-decide-shadow-isolation/fault.sh
. "$SI_SUB/fault.sh"

case_begin "isolation-fault-hang-stops-within-cap" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_fault_hang
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

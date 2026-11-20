#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-shadow-isolation.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# #3068 in-run shadow (b): runs the real CLI on a fixture repo both off and on, and checks that off equals the current code's
# values, that on does not change exit, stdout or the state's baseline_classification, that the EXIT trap
# survives, the divergence log's place, name, format and sweep, and the one stderr line.
# The node body that writes the log (decide-shadow.js) is exercised through the path that calls it from the .sh.
# FAULT is in -fault-fail.sh / -fault-hang.sh, the budget in -budget.sh.
# TL3 gap: the real time of the 10-second watchdog (Windows Git Bash and Linux) is measured in the evidence step.
# Case bodies: bin-run-tests-baseline-decide-shadow-isolation/{cases,_lib}.sh.

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
# shellcheck source=./bin-run-tests-baseline-decide-shadow-isolation/cases.sh
. "$SI_SUB/cases.sh"

si_isolation_setup

case_begin "isolation-kill-switch-off-silent" "bin/run-tests-baseline"
si_case_off
case_end

case_begin "isolation-on-keeps-exit-stdout-state" "bin/run-tests-baseline"
si_case_on_same
case_end

case_begin "isolation-exit-trap-and-tmp-cleanup" "bin/run-tests-baseline"
si_case_exit_trap
case_end

case_begin "log-place-name-header" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_log_place
case_end

case_begin "log-line-shapes-and-counts" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_log_lines
case_end

case_begin "log-retention-sweeps-old-files" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_log_retention
case_end

case_begin "log-stderr-one-line-stdout-clean" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_streams
case_end

case_begin "env-capture-file-kept" "bin/lib/run-tests-baseline-decide-shadow.sh"
si_case_env_capture_kept
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

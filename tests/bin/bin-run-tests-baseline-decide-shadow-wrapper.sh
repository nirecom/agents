#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-shadow-wrapper.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, scope:common, pwsh-not-required, TL2
# #3068 in-run shadow (a): even when rtb_decide_shadow_install wraps rtb_exec_one, the return code, RTB_EXEC_* and
# stdin are unchanged, and exactly one capture file (${LOGDIR}.decide-shadow-capture.tsv) is written.
# Sources the lib inside a child bash and calls the functions directly (driver.sh). A stub launcher decides the result.
# TL3 gap: launching a real test (the real run-all-launch.sh) is owned by the CLI isolation test.
# Case bodies: bin-run-tests-baseline-decide-shadow-wrapper/{cases,_lib,driver}.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_isolate "$(make_tmp)"
WS_SUB="$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-run-tests-baseline-decide-shadow-wrapper"
# shellcheck source=./bin-run-tests-baseline-decide-shadow-wrapper/_lib.sh
. "$WS_SUB/_lib.sh"
# shellcheck source=./bin-run-tests-baseline-decide-shadow-wrapper/cases.sh
. "$WS_SUB/cases.sh"

case_begin "wrapper-transparent-per-launcher-outcome" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_transparent
case_end

case_begin "wrapper-consumes-no-stdin" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_stdin
case_end

case_begin "wrapper-capture-write-failure-transparent" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_write_failure
case_end

case_begin "wrapper-capture-path-fixed-once" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_capture_fixed
case_end

case_begin "wrapper-capture-columns" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_capture_columns
case_end

case_begin "wrapper-logdir-unset-no-abort" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_logdir_unset
case_end

case_begin "wrapper-kill-switch-off-not-installed" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_kill_switch_off
case_end

case_begin "wrapper-double-install-no-rewrap" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_double_install
case_end

case_begin "wrapper-capture-rel-escaped" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_capture_rel_escaped
case_end

case_begin "skip-log-path-escaped" "bin/lib/run-tests-baseline-decide-shadow.sh"
ws_case_skip_log_escaped
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

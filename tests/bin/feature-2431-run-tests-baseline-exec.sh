#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-exec.sh
# Tests: bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, exec, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): exec cases.
# Preamble and parts: feature-2431-run-tests-baseline/_entry.sh.
# TL3 gap: a real session's failing_tests seeding is tested by tests/hooks/feature-2431-run-tests-failing-list.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2431-run-tests-baseline/_entry.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_entry.sh"

case_begin "baseline-exec" "bin/lib/run-tests-baseline-exec.sh"
run_exec_cases
case_end

case_begin "baseline-exec-isolation" "bin/lib/run-tests-baseline-exec.sh"
run_exec_isolation_cases
case_end

case_begin "baseline-exec-state" "bin/lib/run-tests-baseline-exec.sh"
run_exec_state_cases
case_end

case_begin "baseline-exec-grandchild" "bin/lib/run-tests-baseline-exec.sh"
run_exec_grandchild_cases
case_end

case_begin "baseline-exec-unrunnable" "bin/lib/run-tests-baseline-exec.sh"
run_exec_unrunnable_cases
case_end

rtb_entry_finish

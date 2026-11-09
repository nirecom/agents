#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-timeout-derived.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, timeout, ledger, cli, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): CLI cases for
# the derived, default and budget-limited per-test timeout and the value handed to rtb_exec_one.
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

case_begin "baseline-cli-timeout-derive-derived" "bin/run-tests-baseline"
run_timeout_cli_derived_cases
case_end

rtb_entry_finish

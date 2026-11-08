#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-timeout.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, ledger, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): timeout
# derivation unit cases and the CLI explicit/budget cases (derived values:
# feature-2431-run-tests-baseline-timeout-derived.sh).
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

case_begin "baseline-timeout-derive" "bin/lib/run-tests-baseline-timeout.sh"
run_timeout_unit_cases
case_end

case_begin "baseline-cli-timeout-derive" "bin/run-tests-baseline"
run_timeout_cli_cases
case_end

rtb_entry_finish

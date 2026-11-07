#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-homeref.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-homeref.sh
# Tags: run-tests, baseline, homeref, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): home-reference
# unit cases and CLI cases CH1-CH5 (CH6-CH9: feature-2431-run-tests-baseline-homeref-lang.sh).
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

case_begin "baseline-homeref" "bin/lib/run-tests-baseline-homeref.sh"
run_homeref_unit_cases
case_end

case_begin "baseline-cli-homeref" "bin/run-tests-baseline"
run_cli_homeref_cases
case_end

rtb_entry_finish

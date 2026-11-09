#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-cli-state.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): CLI
# ambiguous-exit, unrunnable-at-base and evidence-unmet cases.
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

case_begin "baseline-cli-ambiguous-exit" "bin/run-tests-baseline"
run_cli_ambiguous_exit_cases
case_end

case_begin "baseline-cli-unrunnable-at-base" "bin/run-tests-baseline"
run_cli_unrunnable_at_base_cases
case_end

case_begin "baseline-cli-evidence-unmet" "bin/run-tests-baseline"
run_cli_evidence_unmet_cases
case_end

rtb_entry_finish

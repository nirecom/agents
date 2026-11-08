#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-cli-classes.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): CLI
# undetermined, exec-setup-failed, unsupported-at-base and same-base-pass classes.
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

case_begin "baseline-cli-undetermined" "bin/run-tests-baseline"
run_cli_undetermined_cases
case_end

case_begin "baseline-cli-exec-setup-failed" "bin/run-tests-baseline"
run_cli_exec_setup_failed_cases
case_end

case_begin "baseline-cli-unsupported-at-base" "bin/run-tests-baseline"
run_cli_unsupported_at_base_cases
case_end

case_begin "baseline-cli-same-base-pass-cached" "bin/run-tests-baseline"
run_cli_same_base_pass_cases
case_end

rtb_entry_finish

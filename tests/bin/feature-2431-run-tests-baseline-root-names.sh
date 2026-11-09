#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-root-names.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, root-names, exec, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): root-name decoy cases.
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

case_begin "baseline-root-names-predates-rename" "bin/run-tests-baseline"
run_root_names_cli_cases
case_end

case_begin "baseline-root-names-predicate" "bin/lib/run-tests-baseline-exec.sh"
run_root_names_predicate_cases
case_end

case_begin "baseline-root-names-exec-decoy" "bin/lib/run-tests-baseline-exec.sh"
run_root_names_exec_cases
case_end

case_begin "baseline-root-names-exec-decoy-hit" "bin/lib/run-tests-baseline-exec.sh"
run_root_names_exec_hit_cases
case_end

case_begin "baseline-cli-root-decoy-hit-at-base" "bin/run-tests-baseline"
run_cli_decoy_hit_cases
case_end

rtb_entry_finish

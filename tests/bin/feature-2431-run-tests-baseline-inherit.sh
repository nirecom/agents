#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-inherit.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-ledger.sh
# Tags: run-tests, baseline, ledger, inherit, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): ledger
# inheritance reject and literal-glob cases.
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

case_begin "baseline-ledger-inherit-reject" "bin/run-tests-baseline"
run_ledger_inherit_reject_cases
case_end

case_begin "baseline-ledger-inherit-literal-glob" "bin/run-tests-baseline"
run_ledger_inherit_glob_cases
case_end

rtb_entry_finish

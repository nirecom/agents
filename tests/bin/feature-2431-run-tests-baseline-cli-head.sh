#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline-cli-head.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, approval, scope:issue-specific, pwsh-not-required, TL2
# One split group of the run-tests-baseline suite (feature-2431-run-tests-baseline.sh): the CLI's
# --head hand-off to record and the approval hint (#3067). Preamble and parts: feature-2431-run-tests-baseline/_entry.sh.
# TL3 gap: the model reading the stderr hint and asking the user (skills/run-tests RNT-9) is not run here.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2431-run-tests-baseline/_entry.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_entry.sh"

case_begin "baseline-cli-head" "bin/run-tests-baseline"
run_cli_head_cases
case_end

rtb_entry_finish

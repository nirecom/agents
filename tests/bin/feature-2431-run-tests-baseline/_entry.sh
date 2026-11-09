# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/_entry.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared preamble of every tests/bin/feature-2431-run-tests-baseline*.sh entrypoint: skip gates,
# the decoy cache, the harness, helpers.sh and every part. The parts only define functions, so each
# entrypoint loads all of them and runs its own case groups; the suite is split into several
# entrypoints because run-all runs separate files in parallel. Sourced; never run standalone.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _entry.sh}"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline"

# shellcheck source=./helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./ledger.sh
. "$SUBDIR/ledger.sh"
# shellcheck source=./inherit-reject.sh
. "$SUBDIR/inherit-reject.sh"
# shellcheck source=./worktree.sh
. "$SUBDIR/worktree.sh"
# shellcheck source=./exec.sh
. "$SUBDIR/exec.sh"
# shellcheck source=./cli.sh
. "$SUBDIR/cli.sh"
# shellcheck source=./cli-unsupported.sh
. "$SUBDIR/cli-unsupported.sh"
# shellcheck source=./root-names.sh
. "$SUBDIR/root-names.sh"
# shellcheck source=./cli-decoy-hit.sh
. "$SUBDIR/cli-decoy-hit.sh"
# shellcheck source=./homeref.sh
. "$SUBDIR/homeref.sh"
# shellcheck source=./cli-homeref.sh
. "$SUBDIR/cli-homeref.sh"
# shellcheck source=./derive-timeout.sh
. "$SUBDIR/derive-timeout.sh"
# shellcheck source=./derive-timeout-cli.sh
. "$SUBDIR/derive-timeout-cli.sh"
# shellcheck source=./exec-state.sh
. "$SUBDIR/exec-state.sh"
# shellcheck source=./cli-state.sh
. "$SUBDIR/cli-state.sh"
# shellcheck source=./stage-order.sh
. "$SUBDIR/stage-order.sh"

# rtb_entry_finish — the closing tally; its status is the entrypoint's exit status.
rtb_entry_finish() {
  echo ""
  echo "Total: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

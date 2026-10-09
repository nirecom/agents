#!/usr/bin/env bash
# tests/bin/feat-2490-next-step-gate.sh
# Tests: bin/workflow/lib/next-step/gate-line.js, bin/workflow/lib/next-step/gate-mode.js
# Tags: tl2, workflow, confirm-gate, next-step, runner, scope:issue-specific, pwsh-not-required
# #2490 runner: run-all.sh only discovers tests/bin/*.sh, so this dispatches the subfolder suites.

# TL3 gap (what this test does NOT catch): whether a live model follows GATE_ACTION
# in the seven gate skills. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight,
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2490-next-step-gate"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

RC_ALL=0
FAILED=""
run_suite() {
  local c="$1" rc
  echo "########## $c ##########"
  if bash "$SUBDIR/$c.sh"; then :; else
    rc=$?
    if [ "$rc" -eq 77 ]; then echo "SKIPPED: $c"; else RC_ALL=1; FAILED="$FAILED $c"; fi
  fi
  echo ""
}
case_begin "suite-value-line" "bin/workflow/lib/next-step/gate-line.js"
run_suite value-line
case_end
case_begin "suite-gate-mode" "bin/workflow/lib/next-step/gate-mode.js"
run_suite gate-mode
case_end

echo "########## feat-2490-next-step-gate summary ##########"
if [ "$RC_ALL" -eq 0 ]; then echo "All suites passed."; else echo "Failed suites:$FAILED"; fi
exit "$RC_ALL"

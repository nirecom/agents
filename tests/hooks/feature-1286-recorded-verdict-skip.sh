#!/bin/bash
# tests/hooks/feature-1286-recorded-verdict-skip.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, bin/workflow/record-skip-judgment, hooks/gate-plan-skip-sentinel.js, bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: L2, workflow, skip-signal, scope:issue-specific
#
# Recorded-verdict skip judgment (#1286), at the #2460 end state. Dispatcher only:
# helpers/fixtures in feature-1286-recorded-verdict-skip/helpers.sh, case groups in its siblings.
#
# # L3 gap
# A real session would also prove the hook fires on live PreToolUse events and that
# jev-judge finalize invokes record-skip-judgment; mitigation: bin/check-verification-gate.sh skill-orchestration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TESTS_SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1286-recorded-verdict-skip"

# shellcheck source=./feature-1286-recorded-verdict-skip/helpers.sh
. "$TESTS_SUBDIR/helpers.sh"

# shellcheck source=./feature-1286-recorded-verdict-skip/module-api.sh
. "$TESTS_SUBDIR/module-api.sh"
# shellcheck source=./feature-1286-recorded-verdict-skip/cli.sh
. "$TESTS_SUBDIR/cli.sh"
# shellcheck source=./feature-1286-recorded-verdict-skip/gate.sh
. "$TESTS_SUBDIR/gate.sh"
# shellcheck source=./feature-1286-recorded-verdict-skip/next-step.sh
. "$TESTS_SUBDIR/next-step.sh"
# shellcheck source=./feature-1286-recorded-verdict-skip/next-step-retired-shapes.sh
. "$TESTS_SUBDIR/next-step-retired-shapes.sh"
# shellcheck source=./feature-1286-recorded-verdict-skip/stale-guard.sh
. "$TESTS_SUBDIR/stale-guard.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

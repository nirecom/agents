#!/bin/bash
# tests/feature-1286-recorded-verdict-skip.sh
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js, bin/workflow/record-skip-judgment, hooks/gate-plan-skip-sentinel.js, bin/workflow/next-step
# Tags: L2, workflow, skip-signal, scope:issue-specific
#
# Pre-implementation tests for #1286 (recorded-verdict skip judgment).
# Expected to go green after write-code implements:
#   - recordSkipJudgment / readSkipJudgment / hasValidSkipJudgment in skip-signal-resolver.js
#   - skip_judgment stored at state.steps[targetStep].skip_judgment
#   - bin/workflow/record-skip-judgment CLI
#   - gate-plan-skip-sentinel.js reads hasValidSkipJudgment
#   - next-step marks step skipped on valid recorded judgment
#
# Dispatcher: shared helpers/fixtures live in feature-1286-recorded-verdict-skip/helpers.sh;
# case groups live in module-api.sh, cli.sh, gate.sh, next-step.sh.
#
# # L3 gap
# L2 tests call hooks via direct node invocations and write state fixtures directly.
# A real Claude Code session (L3) would additionally verify:
#   (a) the hook fires on actual PreToolUse events and reads the live session-id;
#   (b) record-skip-judgment is invoked by the orchestrator inside a real CC session;
#   (c) next-step is called by the workflow driver after the sentinel echo.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: skill-orchestration

set -uo pipefail

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
# shellcheck source=./feature-1286-recorded-verdict-skip/stale-guard.sh
. "$TESTS_SUBDIR/stale-guard.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

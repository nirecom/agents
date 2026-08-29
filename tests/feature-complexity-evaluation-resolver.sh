#!/bin/bash
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation
# Tags: L2, workflow, complexity-evaluation, scope:issue-specific
# Issue #1350 — one-time persisted SSOT for the S1..S6 complexity evaluation:
#   recordComplexityEvaluation(sessionId, signals) persists one evaluation, deriving the
#   level itself (#2099); readComplexityEvaluation / hasComplexityEvaluation are fail-open
#   read accessors; bin/workflow/{record,read}-complexity-evaluation wrap them for SKILL.md.
# Nothing here is skippable: lib.sh asserts the required API/CLI surface (CE-REQ-1/2) and
#   every case runs unconditionally, so pre-impl the suite reports FAILs, not SKIPs (R3-C7).
# L3 gap: no real orchestrator-driven flow across CI-C1b/MDP-3/WCD-3/WT-5; the sibling
#   static reader-ordering suites mitigate it.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

# Setup, presence probes, counters, and helpers live in the sibling lib
# (rules/coding/file-split.md Pattern A — entrypoint-private module).
# shellcheck source=tests/feature-complexity-evaluation-resolver/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/lib.sh"

# Cases — sourced fragments (Pattern A split; rules/coding/file-split.md).
# They execute at source time, so this order IS the execution order.
# shellcheck source=tests/feature-complexity-evaluation-resolver/api-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/api-cases.sh"
# shellcheck source=tests/feature-complexity-evaluation-resolver/cli-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/cli-cases.sh"
# shellcheck source=tests/feature-complexity-evaluation-resolver/shim-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/shim-cases.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"

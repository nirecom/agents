#!/usr/bin/env bash
# lang-check: ignore — pre-existing origin/main content, unmodified by this session's merge.
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/advance.js, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/cli.js, bin/workflow/lib/next-step/state-ops.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/not-needed-handlers.js
# Tags: tl2, workflow, next-step, advance, record-step-verdict, scope:issue-specific, pwsh-not-required
#
# #1644 stage 1 — the `--advance` / `--next` forward-operation contract on
# bin/workflow/next-step. Cases A1..A16 of the detail plan's "ステージ ① で投入".
# Written BEFORE the implementation: RED until advance.js / record-step-verdict.js land.
#
# Dispatcher: helpers/fixtures in feature-1644-advance-transaction/helpers.sh;
# case groups in basic.sh, gates.sh, projection.sh.
#
# TL3 gap (what this test does NOT catch):
# - Whether a real Claude Code session's model actually issues the single
#   `--advance --next` call instead of the legacy two-Bash sentinel+next-step pair.
# - Whether settings.json permissions.allow matches the new flag form, so the new
#   call shape runs without an approval dialog in a live session.
# - Whether the PostToolUse workflow-mark hook observes the real command string
#   emitted by the migrated SKILL.md steps.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1644-advance-transaction"

# shellcheck source=./feature-1644-advance-transaction/helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./feature-1644-advance-transaction/basic.sh
. "$SUBDIR/basic.sh"
# shellcheck source=./feature-1644-advance-transaction/gates.sh
. "$SUBDIR/gates.sh"
# shellcheck source=./feature-1644-advance-transaction/projection.sh
. "$SUBDIR/projection.sh"

run_basic_cases
run_gate_cases
run_projection_cases

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

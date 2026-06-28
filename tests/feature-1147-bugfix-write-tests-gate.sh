#!/bin/bash
# Tests: hooks/lib/workflow-state/is-bugfix-session.js, hooks/lib/workflow-state/state-io.js, hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-gate.js, hooks/workflow-gate/review-tests-checker.js
# Tags: workflow, gate, bugfix, write-tests, scope:issue-specific
# L2 broad integration tests for #1147 T0-A: BUGFIX write_tests gate
# L3 gap (what this test does NOT catch):
# - Real Claude session sentinel timing (workflow-mark is a PostToolUse hook; not reproducible without live claude -p session)
# - Real git worktree context for enforce-worktree interplay
# - workflow-gate PreToolUse hook registration in real Claude Code environment
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_DIR="$(cd "$(dirname "$0")/feature-1147-bugfix-write-tests-gate" && pwd)"
TOTAL_ERRORS=0

run_suite() {
    local script="$1"
    local errors
    bash "$SUITE_DIR/$script" "$AGENTS_DIR" || errors=$?
    TOTAL_ERRORS=$((TOTAL_ERRORS + ${errors:-0}))
}

echo "--- Suite: SSOT module (C1-C6) ---"
run_suite "test-ssot-module.sh"

echo ""
echo "--- Suite: Defenses (C7-C11) ---"
run_suite "test-defenses.sh"

echo ""
echo "=== Results ==="
if [ "$TOTAL_ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$TOTAL_ERRORS test(s) failed"
    exit 1
fi

#!/usr/bin/env bash
# Tests: skills/clarify-intent/scripts/run-completion.sh
# Tags: scope:issue-specific
# L2 tests for the scriptified clarify-intent completion logic (issue #1465).
# L3 gap: real GitHub API calls and AGENTS_MAIN_ROOT resolution in a real claude -p
# session; checked at WORKFLOW_USER_VERIFIED preflight (skill-orchestration category).
# Case group: feature-1465-scriptify-clarify-intent/run-completion.sh.

set -uo pipefail

TESTS_SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1465-scriptify-clarify-intent"

PASS=0; FAIL=0; SKIP=0

# shellcheck source=feature-1465-scriptify-clarify-intent/run-completion.sh
. "$TESTS_SUBDIR/run-completion.sh"
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL

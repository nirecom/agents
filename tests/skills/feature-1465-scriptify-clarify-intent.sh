#!/usr/bin/env bash
# Tests: skills/clarify-intent/scripts/run-completion.sh, skills/clarify-intent/scripts/check-complexity-skip.sh
# Tags: scope:issue-specific
#
# L2 integration tests for the scripts that scriptify clarify-intent completion (#1465).
# L3 gap: real clarify-commit-scope.sh / clarify-guard-loop.sh GitHub API calls and
# AGENTS_MAIN_ROOT resolution in a real claude -p session; checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
# Dispatcher (file-split rule): case groups live in feature-1465-scriptify-clarify-intent/
# (run-completion.sh, run-completion-approval.sh, check-complexity-skip.sh).

set -uo pipefail

TESTS_SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1465-scriptify-clarify-intent"

PASS=0; FAIL=0; SKIP=0

# shellcheck source=feature-1465-scriptify-clarify-intent/run-completion.sh
. "$TESTS_SUBDIR/run-completion.sh"
# shellcheck source=feature-1465-scriptify-clarify-intent/run-completion-approval.sh
. "$TESTS_SUBDIR/run-completion-approval.sh"
# shellcheck source=feature-1465-scriptify-clarify-intent/check-complexity-skip.sh
. "$TESTS_SUBDIR/check-complexity-skip.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL

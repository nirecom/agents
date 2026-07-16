#!/usr/bin/env bash
# Tests: skills/clarify-intent/scripts/run-completion.sh, skills/clarify-intent/scripts/check-complexity-skip.sh
# Tags: scope:issue-specific
#
# L2 broad integration tests for two shell scripts that scriptify the
# clarify-intent completion logic from SKILL.md (issue #1465).
#
# L3 gap (what this test does NOT catch):
# - Real clarify-commit-scope.sh / clarify-guard-loop.sh network calls against GitHub API
# - AGENTS_CONFIG_DIR resolution in a real claude -p session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Test-first: source scripts do not exist yet. All tests will FAIL (file-not-found) until
# write-code creates the scripts. That is expected and documented here.
#
# Dispatcher (file-split rule: >500 lines).
# Case groups live in feature-1465-scriptify-clarify-intent/run-completion.sh
# and feature-1465-scriptify-clarify-intent/check-complexity-skip.sh.

set -uo pipefail

TESTS_SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1465-scriptify-clarify-intent"

PASS=0; FAIL=0; SKIP=0

# shellcheck source=feature-1465-scriptify-clarify-intent/run-completion.sh
. "$TESTS_SUBDIR/run-completion.sh"
# shellcheck source=feature-1465-scriptify-clarify-intent/check-complexity-skip.sh
. "$TESTS_SUBDIR/check-complexity-skip.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL

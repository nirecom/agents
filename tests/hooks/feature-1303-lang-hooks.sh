#!/usr/bin/env bash
# filename: tests/feature-1303-lang-hooks.sh
# Tests: hooks/lang-inject.js, hooks/subagent-start.js, settings.json, install/assemble-settings.js
# Tags: hook-injection, lang-inject, subagent-start, plan-lang, scope:issue-specific, pwsh-not-required
#
# Dispatch entrypoint. All test logic lives in tests/feature-1303-lang-hooks/.
#
# L3 gap (what this test does NOT catch):
# - Whether UserPromptSubmit hook actually fires in a live claude -p session
# - Whether SubagentStart hook fires for the whitelisted agent_type values
#   in a real session context
# - Whether additionalContext from lang-inject.js is surfaced to the model
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/feature-1303-lang-hooks/helpers.sh"
source "$SCRIPT_DIR/feature-1303-lang-hooks/group1-lang-inject.sh"
source "$SCRIPT_DIR/feature-1303-lang-hooks/group2-subagent-start.sh"
source "$SCRIPT_DIR/feature-1303-lang-hooks/group3-settings.sh"

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

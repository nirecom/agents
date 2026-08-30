#!/usr/bin/env bash
# filename: tests/fix-supervisor-subagent-lang.sh
# Tests: settings.json, hooks/subagent-start.js, agents
# Tags: hook-registration, pwsh-not-required, conv-lang, subagent-lang, scope:common
#
# Dispatch entrypoint; logic in tests/fix-supervisor-subagent-lang/.
# L3 gap: subagent output language only testable via live `claude -p`. This test
# verifies hook-shape only. Mitigation: WORKFLOW_USER_VERIFIED / hook-registration gate.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/helpers.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/unit-settings-language.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/integration-subagent-start.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/unit-agent-fallback-line.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

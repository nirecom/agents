#!/usr/bin/env bash
# filename: tests/fix-supervisor-subagent-lang.sh
# Tests: settings.json, hooks/subagent-start.js, agents/*.md
# Tags: hook-registration, pwsh-not-required, conv-lang, subagent-lang
#
# Dispatch entrypoint. All test logic lives in tests/fix-supervisor-subagent-lang/.
#
# L3 gap (what this test does NOT catch):
# - hooks/subagent-start.js authority over real subagent output language can only
#   be verified in a live `claude -p` spawn; this test verifies hook-shape only.
# - settings.json "language" field propagation to subagents is undocumented; real
#   behavior is only observable in a live Claude Code session.
# Closest-to-action mitigation: Step 4 manual verification gate
# (new CC session, Probe A / B-supervisor / B-planner) at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/helpers.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/unit-settings-language.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/integration-subagent-start.sh"
source "$SCRIPT_DIR/fix-supervisor-subagent-lang/unit-agent-fallback-line.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

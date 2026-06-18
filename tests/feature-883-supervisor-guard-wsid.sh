#!/bin/bash
# tests/feature-883-supervisor-guard-wsid.sh
# Tests: hooks/supervisor-guard.js, hooks/lib/supervisor-report-format.js
# Tags: supervisor, em-supervisor, session-id, workflow-state, layer2, hook, stop, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Claude Code Stop hook registration in settings.json
# - Guard running inside a real Claude Code session (CLAUDECODE env var, real transcript JSONL format)
# - resolveWorkflowSessionId reading from a real git worktree hierarchy
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
# RED for issue #883/#913.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/feature-883-supervisor-guard-wsid/_lib.sh
. "$SCRIPT_DIR/feature-883-supervisor-guard-wsid/_lib.sh"
# shellcheck source=tests/feature-883-supervisor-guard-wsid/cases-g20-g33.sh
. "$SCRIPT_DIR/feature-883-supervisor-guard-wsid/cases-g20-g33.sh"
# shellcheck source=tests/feature-883-supervisor-guard-wsid/cases-g34-g41.sh
. "$SCRIPT_DIR/feature-883-supervisor-guard-wsid/cases-g34-g41.sh"

run_g20; run_g21; run_g22; run_g23; run_g24
run_g25; run_g26; run_g27; run_g28; run_g29
run_g30; run_g31; run_g32; run_g33
run_g34; run_g35; run_g36; run_g37; run_g38
run_g39; run_g40; run_g41
run_g42; run_g43; run_g44
run_g45; run_g46; run_g47
run_g48; run_g49; run_g50

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

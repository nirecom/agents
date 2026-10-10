#!/usr/bin/env bash
# filename: tests/hooks/fix-conv-lang-inject.sh
# Tests: hooks/lib/conv-lang.js, hooks/post-compact.js, hooks/workflow-mark.js
# Tags: scope:issue-specific
#
# Dispatch entrypoint. All test logic lives in tests/hooks/fix-conv-lang-inject/.
#
# L3 gap (what this test does NOT catch):
# - Claude Code surfacing additionalContext from SessionStart/PostCompact hooks
#   in a live `claude -p` session (hook output shape is all we can verify here)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fix-conv-lang-inject/helpers.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/unit-helper.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/integration-session-start.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/integration-post-compact.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/integration-workflow-mark.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

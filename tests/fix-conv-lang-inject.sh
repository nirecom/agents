#!/usr/bin/env bash
# filename: tests/fix-conv-lang-inject.sh
# Tests: hooks/lib/conv-lang.js, hooks/session-start.js, hooks/post-compact.js
# Tags: hook-injection, conv-lang
#
# Dispatch entrypoint. All test logic lives in tests/fix-conv-lang-inject/.
#
# L3 gap (what this test does NOT catch):
# - Claude Code surfacing additionalContext from SessionStart/PostCompact hooks
#   in a live `claude -p` session (hook output shape is all we can verify here)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fix-conv-lang-inject/helpers.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/unit-helper.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/integration-session-start.sh"
source "$SCRIPT_DIR/fix-conv-lang-inject/integration-post-compact.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

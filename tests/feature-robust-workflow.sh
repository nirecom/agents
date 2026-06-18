#!/bin/bash
# Tests: hooks/lib/is-private-repo.js, hooks/lib/workflow-state.js, hooks/session-start.js, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, bin, git
# Test suite for workflow state machine:
#   claude-global/hooks/workflow-gate.js   (PreToolUse commit gate)
#   claude-global/hooks/session-start.js   (SessionStart hook)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-mark.js"
SESSION_START="$DOTFILES_DIR/claude-global/hooks/session-start.js"
SETTINGS="$DOTFILES_DIR/claude-global/settings.json"
WS_REL="./claude-global/hooks/lib/workflow-state.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout: use system timeout if available, else perl alarm
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPT_DIR/feature-robust-workflow/helpers.sh"
. "$SCRIPT_DIR/feature-robust-workflow/workflow-gate.sh"
. "$SCRIPT_DIR/feature-robust-workflow/session-start.sh"
. "$SCRIPT_DIR/feature-robust-workflow/workflow-mark.sh"
. "$SCRIPT_DIR/feature-robust-workflow/settings-e2e.sh"
. "$SCRIPT_DIR/feature-robust-workflow/workflow-state.sh"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi

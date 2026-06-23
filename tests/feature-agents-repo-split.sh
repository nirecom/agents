#!/bin/bash
# Tests: agents/install/linux/dotfileslink.sh, agents/install/win/dotfileslink.ps1, agents/profile-snippet.ps1, agents/profile-snippet.sh, bin/scan-outbound, bin/scan-outbound.sh, bin/session-sync, bin/session-sync.sh, bin/split-history.py, hooks/commit-msg, hooks/pre-commit
# Tags: scan, filter, outbound, hook, git
# Smoke tests for agents repo split (steps 2, 8, 16).
# Verifies: settings.json hook path uses $AGENTS_CONFIG_DIR/hooks/,
#           dotfiles → agents compat blocks removed,
#           .agents_profile sourcing added on both shells,
#           dotfileslink scripts write profile snippet with AGENTS_CONFIG_DIR
#           and CLAUDE.md/settings.json symlink repair logic.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTFILES_ROOT=""
if [ -d "$AGENTS_ROOT/../dotfiles" ]; then
    DOTFILES_ROOT="$(cd "$AGENTS_ROOT/../dotfiles" && pwd)"
fi
SETTINGS="$AGENTS_ROOT/settings.json"
PROFILE_COMMON="${DOTFILES_ROOT:+$DOTFILES_ROOT/.profile_common}"
PROFILE_PS1="${DOTFILES_ROOT:+$DOTFILES_ROOT/install/win/profile.ps1}"
ERRORS=0
SKIPS=0
PASSES=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }

# Only the agents-side settings.json is mandatory.
if [ ! -f "$SETTINGS" ]; then
    echo "FATAL: required file not found: $SETTINGS"
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-agents-repo-split"
# shellcheck source=/dev/null
. "$SUB_DIR/section-n1-n15.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-step16.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-e2e.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-split-history-a.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-split-history-b.sh"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASSES + ERRORS + SKIPS))
echo "Passed:  $PASSES"
echo "Failed:  $ERRORS"
echo "Skipped: $SKIPS"
echo "Total:   $TOTAL"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi

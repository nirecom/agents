#!/usr/bin/env bash
# Structural tests for install/linux/dotfileslink.sh — verifies claude-global/agents symlink entry
# Does NOT execute the install script (would touch real $HOME).
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DOTFILES_DIR/install/linux/dotfileslink.sh"

echo "=== dotfileslink.sh: claude-global/agents symlink entry ==="

# Normal: backup loop includes 'agents'
if grep -qE '^[[:space:]]*for dir in .* agents' "$SCRIPT"; then
    pass "backup loop iterates over 'agents'"
else
    fail "backup loop does not include 'agents'"
fi

# Normal: ln -snf line for agents exists
if grep -qF 'ln -snf ~/dotfiles/claude-global/agents ~/.claude/agents' "$SCRIPT"; then
    pass "ln -snf ~/dotfiles/claude-global/agents ~/.claude/agents exists"
else
    fail "ln -snf line for agents is missing"
fi

# Idempotency: ln -snf .* claude-global/agents appears exactly once
count=$(grep -cE 'ln -snf .*claude-global/agents' "$SCRIPT")
if [ "$count" -eq 1 ]; then
    pass "ln -snf ... claude-global/agents appears exactly once (got $count)"
else
    fail "ln -snf ... claude-global/agents should appear once, got $count"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

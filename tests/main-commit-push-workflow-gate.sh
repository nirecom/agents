#!/bin/bash
# Regression test: commit-push skill must not have a model: directive that would
# cause it to spawn a subagent with a fresh session ID, bypassing workflow-gate.
#
# Root cause: commit-push SKILL.md had `model: haiku` which caused the Skill tool
# to spawn a new agent with a new session UUID. The new session has all workflow
# steps pending → workflow-gate blocks the git commit.
# Fix: Remove model: directive so commit-push runs in the main conversation session.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_FILE="$DOTFILES_DIR/claude-global/skills/commit-push/SKILL.md"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Test 1: SKILL.md must not contain a model: directive
# ---------------------------------------------------------------------------
# A model: directive causes the Skill runner to spawn a subagent with a new
# session ID. That new session has no workflow state → workflow-gate blocks all
# git commits. The skill must run in the caller's session (no model override).

if grep -q '^model:' "$SKILL_FILE"; then
    fail "commit-push SKILL.md has 'model:' directive — will spawn subagent and bypass workflow-gate"
else
    pass "commit-push SKILL.md has no model: directive (runs in caller's session)"
fi

# ---------------------------------------------------------------------------
# Test 2: SKILL.md must not contain an effort: directive
# ---------------------------------------------------------------------------
# effort: is paired with model: — both should be absent.

if grep -q '^effort:' "$SKILL_FILE"; then
    fail "commit-push SKILL.md has 'effort:' directive — remove together with model:"
else
    pass "commit-push SKILL.md has no effort: directive"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi

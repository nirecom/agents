#!/usr/bin/env bash
# Structural tests: reasoning-heavy skills and agents must have explicit model: opus
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Explicit model: opus tests ==="

# Skills that must have model: opus
OPUS_SKILLS="deep-research make-plan review-security write-tests"
for skill in $OPUS_SKILLS; do
    file="$DOTFILES_DIR/claude-global/skills/$skill/SKILL.md"
    if [ ! -f "$file" ]; then
        fail "$skill: SKILL.md not found"
        continue
    fi
    if grep -qE '^model: opus$' "$file"; then
        pass "$skill has model: opus"
    else
        fail "$skill missing model: opus"
    fi
done

# Agents that must have model: opus
OPUS_AGENTS="planner reviewer"
for agent in $OPUS_AGENTS; do
    file="$DOTFILES_DIR/claude-global/agents/$agent.md"
    if [ ! -f "$file" ]; then
        fail "$agent: agent file not found"
        continue
    fi
    if grep -qE '^model: opus$' "$file"; then
        pass "$agent agent has model: opus"
    else
        fail "$agent agent missing model: opus"
    fi
done

# Skills that should NOT be opus (lightweight tasks)
NONOPUS_SKILLS="commit-push survey-code review-tests update-docs update-instruction save-research"
for skill in $NONOPUS_SKILLS; do
    file="$DOTFILES_DIR/claude-global/skills/$skill/SKILL.md"
    if [ ! -f "$file" ]; then
        continue  # skip if skill doesn't exist
    fi
    if grep -qE '^model: opus$' "$file"; then
        fail "$skill should not use model: opus (lightweight task)"
    else
        pass "$skill does not use model: opus"
    fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

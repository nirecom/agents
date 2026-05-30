#!/usr/bin/env bash
# phase4-worktree-backup.sh — PASS (baseline pin)
# Pins the existence and basic structure of worktree-end Step 5 backup mechanism.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/worktree-end/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# Step 5 backup section must exist
if grep -qiE 'Step 5|inventory|backup' "$SKILL"; then
  pass "worktree-end SKILL.md contains backup/inventory step"
else
  fail "worktree-end SKILL.md missing backup/inventory step"
fi

# capture-env.sh must exist (Step 5.5)
if [ -f "$AGENTS_DIR/skills/worktree-end/scripts/capture-env.sh" ]; then
  pass "capture-env.sh exists"
else
  fail "capture-env.sh missing"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

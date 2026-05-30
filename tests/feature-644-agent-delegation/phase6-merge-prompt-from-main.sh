#!/usr/bin/env bash
# phase6-merge-prompt-from-main.sh — PASS (baseline pin)
# Merge prompt (AskUserQuestion + gh pr merge) must always stay in main SKILL.md.
# This invariant must hold pre- and post-Phase 6.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/commit-push/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# Merge interaction must be present in SKILL.md
if grep -qE 'gh pr merge|Merge|merge.*prompt|WORKFLOW_USER_VERIFIED' "$SKILL"; then
  pass "merge prompt / gh pr merge present in commit-push SKILL.md"
else
  fail "merge prompt missing from commit-push SKILL.md (must stay in main)"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

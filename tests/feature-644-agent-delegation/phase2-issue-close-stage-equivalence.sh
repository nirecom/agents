#!/usr/bin/env bash
# phase2-issue-close-stage-equivalence.sh — PASS (baseline pin)
# Pins the pre-change issue-close-stage SKILL.md structure.
# Phase 2 must not break the pre-flight checks or final report line.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/issue-close-stage/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# Pre-flight: linked worktree check must be present
if grep -q 'NON_GITHUB\|linked worktree\|pre.flight\|Pre-flight\|Pre.flight' "$SKILL"; then
  pass "pre-flight check present in issue-close-stage"
else
  fail "pre-flight check missing from issue-close-stage"
fi

# bin/github-issues scripts must exist (issue-close-stage uses them)
if [ -d "$AGENTS_DIR/bin/github-issues" ]; then
  pass "bin/github-issues/ exists"
else
  fail "bin/github-issues/ missing"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

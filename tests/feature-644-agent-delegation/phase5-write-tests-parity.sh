#!/usr/bin/env bash
# phase5-write-tests-parity.sh — PASS (baseline pin)
# Pins the pre-change write-tests subagent prompt structure.
# Phase 5 must not remove required fields; new fields are additive only.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/write-tests/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# write-tests must delegate to a subagent (Agent call)
if grep -q 'Agent(' "$SKILL" || grep -q 'subagent' "$SKILL"; then
  pass "write-tests SKILL.md uses subagent delegation"
else
  fail "write-tests SKILL.md missing subagent delegation"
fi

# CONFIRM_TESTS gate must still be present
if grep -q 'CONFIRM_TESTS' "$SKILL"; then
  pass "CONFIRM_TESTS gate present in write-tests SKILL.md"
else
  fail "CONFIRM_TESTS gate missing from write-tests SKILL.md"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

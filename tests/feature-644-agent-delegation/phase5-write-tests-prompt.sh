#!/usr/bin/env bash
# phase5-write-tests-prompt.sh — GATED until Phase 5
# After Phase 5: write-tests SKILL.md subagent prompt must include
# structured fields: task_complexity_signals, source_files, planned_cases.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/write-tests/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

for field in task_complexity_signals source_files planned_cases; do
  if grep -q "$field" "$SKILL"; then
    pass "write-tests SKILL.md subagent prompt contains $field"
  else
    fail "write-tests SKILL.md subagent prompt missing $field"
  fi
done

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

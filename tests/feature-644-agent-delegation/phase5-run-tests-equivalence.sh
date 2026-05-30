#!/usr/bin/env bash
# phase5-run-tests-equivalence.sh — PASS (baseline pin)
# run-tests SKILL.md already delegates to test-runner subagent.
# This test verifies the invariant is maintained pre- and post-Phase 5 change.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/run-tests/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# Must delegate to test-runner subagent (pre-existing, must not be removed)
if grep -q 'test-runner' "$SKILL"; then
  pass "run-tests SKILL.md delegates to test-runner subagent"
else
  fail "run-tests SKILL.md missing test-runner delegation (regression)"
fi

# sentinel emit must be present in SKILL.md
if grep -q 'WORKFLOW_MARK_STEP_run_tests' "$SKILL"; then
  pass "run_tests sentinel emit present in SKILL.md"
else
  fail "run_tests sentinel emit missing from SKILL.md"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

#!/usr/bin/env bash
# phase1-sentinel-from-main.sh — GATED until Phase 1
# After Phase 1: update-docs SKILL.md must have Agent(...) call AND
# sentinel emit outside the Agent(...) block (sentinel stays in main).
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 1 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=1 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/update-docs/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }

# Must contain an Agent( call (doc-append-worker delegation)
if grep -q 'Agent(' "$SKILL"; then
  pass "update-docs SKILL.md contains Agent( call"
else
  fail "update-docs SKILL.md missing Agent( call"
fi

# WORKFLOW_MARK_STEP must appear outside any Agent() block
# Simple check: WORKFLOW_MARK sentinel line is present
if grep -q 'WORKFLOW_MARK_STEP' "$SKILL"; then
  pass "sentinel emit present in update-docs SKILL.md"
else
  fail "sentinel emit missing from update-docs SKILL.md"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

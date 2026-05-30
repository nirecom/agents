#!/usr/bin/env bash
# phase2-skill-grep.sh — GATED until Phase 2
# After Phase 2: issue-close-stage SKILL.md must delegate to issue-close-stage-worker via Agent().
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 2 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=2 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/issue-close-stage/SKILL.md"
WORKER="$AGENTS_DIR/agents/issue-close-stage-worker.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }
[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }

if grep -q 'issue-close-stage-worker' "$SKILL"; then
  pass "issue-close-stage SKILL.md delegates to issue-close-stage-worker"
else
  fail "issue-close-stage SKILL.md missing delegation to issue-close-stage-worker"
fi

# Worker must not emit WORKFLOW_ sentinels
if grep -q 'WORKFLOW_' "$WORKER"; then
  fail "issue-close-stage-worker emits WORKFLOW_ sentinel (must not)"
else
  pass "issue-close-stage-worker does not emit WORKFLOW_ sentinels"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

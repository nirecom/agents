#!/usr/bin/env bash
# phase2-skill-grep.sh — GATED until Phase 2
# After Phase 2: issue-close-stage SKILL.md must delegate its Bash chain to a worker.
# #1673 retargeted the delegate from the `issue-close-stage-worker` subagent
# (agents/issue-close-stage-worker.md) to the deterministic dispatcher worker
# module bin/worker-dispatch/workers/issue-close-stage.js.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 2 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=2 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/issue-close-stage/SKILL.md"
WORKER="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-stage.js"
LEGACY="$AGENTS_DIR/agents/issue-close-stage-worker.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }
[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }

if grep -q 'issue-close-stage' "$SKILL" && grep -q 'worker-dispatch.md' "$SKILL"; then
  pass "issue-close-stage SKILL.md dispatches issue-close-stage per worker-dispatch.md"
else
  fail "issue-close-stage SKILL.md missing worker-dispatch delegation"
fi

# The retired subagent must be gone — a leftover md would keep two delegation
# paths alive for the same step.
if [ -e "$LEGACY" ]; then
  fail "agents/issue-close-stage-worker.md still present (retired by #1673)"
else
  pass "agents/issue-close-stage-worker.md retired"
fi

# Worker must not emit WORKFLOW_ sentinels. Matched on the emission form
# `<<WORKFLOW_` so that reading env vars such as WORKFLOW_PLANS_DIR — which the
# dispatcher worker legitimately does — is not mistaken for an emission.
if grep -q '<<WORKFLOW_' "$WORKER"; then
  fail "issue-close-stage worker emits WORKFLOW_ sentinel (must not)"
else
  pass "issue-close-stage worker does not emit WORKFLOW_ sentinels"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

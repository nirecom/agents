#!/usr/bin/env bash
# phase6-commit-push-flow.sh — GATED until Phase 6
# After Phase 6: commit-push SKILL.md must delegate git/gh operations to a worker.
# #1673 retargeted the delegate from the `commit-push-worker` subagent to the
# deterministic dispatcher module bin/worker-dispatch/workers/commit-push.js.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 6 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=6 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/commit-push/SKILL.md"
WORKER="$AGENTS_DIR/bin/worker-dispatch/workers/commit-push.js"
LEGACY="$AGENTS_DIR/agents/commit-push-worker.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }
[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }

# SKILL must dispatch the worker
if grep -q 'commit-push' "$SKILL" && grep -q 'worker-dispatch.md' "$SKILL"; then
  pass "commit-push SKILL.md dispatches commit-push per worker-dispatch.md"
else
  fail "commit-push SKILL.md missing worker-dispatch delegation"
fi

if [ -e "$LEGACY" ]; then
  fail "agents/commit-push-worker.md still present (retired by #1673)"
else
  pass "agents/commit-push-worker.md retired"
fi

# Worker must NOT emit WORKFLOW_ sentinels (emission form only — the module
# legitimately reads WORKFLOW_* env vars to drive the gate).
if grep -q '<<WORKFLOW_' "$WORKER"; then
  fail "commit-push worker emits WORKFLOW_ sentinel (must not)"
else
  pass "commit-push worker does not emit sentinels"
fi

# Worker must not call AskUserQuestion
if grep -q 'AskUserQuestion' "$WORKER"; then
  fail "commit-push worker calls AskUserQuestion (must not)"
else
  pass "commit-push worker does not call AskUserQuestion"
fi

# Worker must not force-push. `--force-with-lease` stays permitted (rules/git.md),
# so the pattern excludes it; `-f` is matched only as a quoted argv token, since
# a bare `-f\b` would hit ordinary prose/identifiers inside a JS module.
if grep -qE '\-\-force([^-]|$)' "$WORKER" || grep -qE '"-f"|'"'"'-f'"'"'' "$WORKER"; then
  fail "commit-push worker uses --force/-f (prohibited)"
else
  pass "commit-push worker does not use force push flags"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

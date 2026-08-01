#!/usr/bin/env bash
# phase3-finalize-multipass.sh — GATED until Phase 3
# After Phase 3: issue-close-finalize SKILL.md must use the multi-pass worker pattern.
# Worker must NOT call /issue-close-finalize internally (recursion owned by main).
# #1673 retargeted the delegate from the `issue-close-finalize-worker` subagent
# to bin/worker-dispatch/workers/issue-close-finalize.js; the prose contract
# moved to docs/architecture/claude-code/worker-dispatch/close-family.md.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 3 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=3 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
WORKER="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-finalize.js"
LEGACY="$AGENTS_DIR/agents/issue-close-finalize-worker.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }
[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }

# SKILL must dispatch the worker
if grep -q 'issue-close-finalize' "$SKILL" && grep -q 'worker-dispatch.md' "$SKILL"; then
  pass "SKILL.md dispatches issue-close-finalize per worker-dispatch.md"
else
  fail "SKILL.md missing worker-dispatch delegation"
fi

if [ -e "$LEGACY" ]; then
  fail "agents/issue-close-finalize-worker.md still present (retired by #1673)"
else
  pass "agents/issue-close-finalize-worker.md retired"
fi

# Worker must NOT invoke the skill itself (no recursive calls from the worker)
if grep -q '/issue-close-finalize' "$WORKER"; then
  fail "issue-close-finalize worker contains /issue-close-finalize call (recursion must stay in main)"
else
  pass "issue-close-finalize worker does not recurse"
fi

# Worker must not emit WORKFLOW_ sentinels. Emission form only — the module
# legitimately reads WORKFLOW_PLANS_DIR.
if grep -q '<<WORKFLOW_' "$WORKER"; then
  fail "issue-close-finalize worker emits WORKFLOW_ sentinel (must not)"
else
  pass "issue-close-finalize worker does not emit WORKFLOW_ sentinels"
fi

# SKILL must contain AskUserQuestion (G.5-2 stays in main)
if grep -q 'AskUserQuestion' "$SKILL"; then
  pass "AskUserQuestion retained in SKILL.md (G.5-2 in main)"
else
  fail "AskUserQuestion missing from SKILL.md"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

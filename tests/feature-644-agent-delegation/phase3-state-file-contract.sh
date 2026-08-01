#!/usr/bin/env bash
# phase3-state-file-contract.sh — GATED until Phase 3
# Verifies the state file schema contract for the issue-close-finalize worker.
# #1673: the contract text moved from agents/issue-close-finalize-worker{,.md,/state-schema.md}
# to docs/architecture/claude-code/worker-dispatch/close-family.md, and the
# implementation of the same contract lives in
# bin/worker-dispatch/workers/issue-close-finalize/state.js.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 3 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=3 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$AGENTS_DIR/docs/architecture/claude-code/worker-dispatch/close-family.md"
STATE="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-finalize/state.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$DOC" ] || { fail "$DOC not found"; exit 1; }
[ -f "$STATE" ] || { fail "$STATE not found"; exit 1; }

# Contract doc must carry schema_version 3
if grep -qE 'schema_version.*3' "$DOC"; then
  pass "contract doc references schema_version 3"
else
  fail "contract doc missing schema_version 3 reference"
fi

# The atomic write is now executable, not prose: state.js must go through the
# fsguard rename helper rather than writing the state file in place.
if grep -qE 'renameWithin|\.tmp' "$STATE"; then
  pass "state.js implements the atomic write pattern"
else
  fail "state.js missing atomic write pattern"
fi

# g5_history and the g5_3a_completed idempotency flag must exist in BOTH the
# contract doc and the implementation — a field documented but never written
# (or written but never documented) is the drift this pair exists to catch.
for field in g5_history g5_3a_completed; do
  if grep -q "$field" "$DOC"; then
    pass "contract doc references $field"
  else
    fail "contract doc missing $field"
  fi
  if grep -q "$field" "$STATE"; then
    pass "state.js references $field"
  else
    fail "state.js missing $field"
  fi
done

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

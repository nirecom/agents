#!/usr/bin/env bash
# phase3-state-file-contract.sh — GATED until Phase 3
# Verifies the state file schema contract for issue-close-finalize-worker.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 3 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=3 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$AGENTS_DIR/agents/issue-close-finalize-worker.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }

# Worker must reference schema_version: 3
if grep -q 'schema_version.*3\|schema_version: 3' "$WORKER"; then
  pass "worker references schema_version 3"
else
  fail "worker missing schema_version 3 reference"
fi

# Worker must reference atomic write pattern (tmp → mv)
if grep -qE '\.tmp.*mv|atomic' "$WORKER"; then
  pass "worker references atomic write pattern"
else
  fail "worker missing atomic write pattern"
fi

# Worker must reference g5_history array
if grep -q 'g5_history' "$WORKER"; then
  pass "worker references g5_history"
else
  fail "worker missing g5_history field"
fi

# Worker must reference g5_3a_completed idempotency flag
if grep -q 'g5_3a_completed' "$WORKER"; then
  pass "worker references g5_3a_completed idempotency flag"
else
  fail "worker missing g5_3a_completed idempotency guard"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

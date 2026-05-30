#!/usr/bin/env bash
# phase4-secret-not-in-manifest.sh — PASS (baseline pin)
# Verifies that worktree-backup-worker definition prohibits writing secrets to manifest.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# If worker exists, verify secret prohibition
WORKER="$AGENTS_DIR/agents/worktree-backup-worker.md"
if [ -f "$WORKER" ]; then
  if grep -qiE 'secret.*manifest|manifest.*secret|no.*secret|secret.*prohibit|never.*secret' "$WORKER"; then
    pass "worktree-backup-worker prohibits secrets in manifest"
  else
    fail "worktree-backup-worker missing secret prohibition"
  fi
else
  # Worker doesn't exist yet (pre-Phase 4) — baseline passes trivially
  pass "worktree-backup-worker not yet created (pre-Phase 4, baseline)"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

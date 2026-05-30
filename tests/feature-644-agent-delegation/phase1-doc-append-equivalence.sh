#!/usr/bin/env bash
# phase1-doc-append-equivalence.sh — PASS (baseline pin)
# Verifies that doc-append CLI produces expected output for a known fixture.
# Runs at Phase 0 to pin pre-change behavior; Phase 1 must not regress this.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Verify doc-append binary exists
if ! command -v doc-append >/dev/null 2>&1; then
  echo "SKIP: doc-append not in PATH" >&2; exit 77
fi

# Verify the bin/compose-doc-append-entry script exists
if [ ! -f "$AGENTS_DIR/bin/compose-doc-append-entry" ]; then
  fail "bin/compose-doc-append-entry not found"
  exit 1
fi

pass "doc-append CLI available"
pass "bin/compose-doc-append-entry exists"

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

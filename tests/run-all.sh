#!/usr/bin/env bash
# tests/run-all.sh — Run all (or specified) test scripts, with exit 77 → skip support.
#
# Usage:
#   tests/run-all.sh [<glob-or-file> ...]
#
# Phase gating (feature-644):
#   FEATURE_644_PHASE=<N>  Run tests gated at phase ≤N (default: 0 = baseline only)
#
# Exit codes:
#   0  All run tests passed (skips ignored)
#   1  One or more tests failed

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$AGENTS_DIR/tests"

export FEATURE_644_PHASE="${FEATURE_644_PHASE:-0}"

PASS=0
FAIL=0
SKIP=0

run_test() {
  local script="$1"
  bash "$script"
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $script"
    PASS=$((PASS + 1))
  elif [ "$rc" -eq 77 ]; then
    echo "SKIP: $script"
    SKIP=$((SKIP + 1))
  else
    echo "FAIL: $script (exit $rc)"
    FAIL=$((FAIL + 1))
  fi
}

if [ $# -gt 0 ]; then
  for pattern in "$@"; do
    for f in $pattern; do
      [ -f "$f" ] && run_test "$f"
    done
  done
else
  for f in "$TESTS_DIR"/*.sh; do
    [ -f "$f" ] && run_test "$f"
  done
fi

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

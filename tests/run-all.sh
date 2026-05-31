#!/usr/bin/env bash
# tests/run-all.sh — Run all (or specified) test scripts, with exit 77 → skip support.
# Tests: tests/run-all.sh
# Tags: run-all, test-runner
#
# Usage:
#   tests/run-all.sh [--all | <glob-or-file> ...]
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

if [ $# -gt 0 ] && [ "$1" = "--all" ]; then
  shift
  # _archive/ is auto-excluded — *.sh matches top-level files only
  for f in "$TESTS_DIR"/*.sh; do
    [ -f "$f" ] && run_test "$f"
  done
elif [ $# -gt 0 ]; then
  for pattern in "$@"; do
    for f in $pattern; do
      [ -f "$f" ] && run_test "$f"
    done
  done
else
  # _archive/ is auto-excluded — *.sh matches top-level files only
  for f in "$TESTS_DIR"/*.sh; do
    [ -f "$f" ] && run_test "$f"
  done
fi

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

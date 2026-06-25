#!/usr/bin/env bash
# Tests: hooks/lib/is-plan-artifact.js
# Tags: workflow, plans, hook, scope:common
# Unit tests for hooks/lib/is-plan-artifact.js
#
# NOTE: source file does not exist until write-code creates it.
# Run after write-code to exercise real behavior.
#
# L3 gap (what this test does NOT catch):
# - Whether check-plan-lang.js wires up isPlanArtifact correctly in a live hook invocation
# - Whether the hook fires for UUID session IDs in a real Claude Code session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
LIB="$AGENTS_DIR/hooks/lib/is-plan-artifact.js"
ERRORS=0
SKIPS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP (EXPECTED_FAIL pre-write-code): $1"; SKIPS=$((SKIPS + 1)); }

# Portable timeout wrapper (rules/test/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Source does not exist yet — skip all tests until write-code creates it.
if [[ ! -f "$LIB" ]]; then
  echo "NOTE: $LIB not found — all tests EXPECTED_FAIL (pre-write-code)"
  skip "T1: timestamp format, intent — 20260620-202454-intent.md → true"
  skip "T2: timestamp format, outline — 20260620-202454-outline.md → true"
  skip "T3: timestamp format, detail — 20260620-202454-detail.md → true"
  skip "T4: UUID format, intent — a4e0c908-daa0-4889-8883-4ef6589f1255-intent.md → true"
  skip "T5: UUID format, outline — a4e0c908-daa0-4889-8883-4ef6589f1255-outline.md → true"
  skip "T6: UUID format, detail — a4e0c908-daa0-4889-8883-4ef6589f1255-detail.md → true"
  skip "T7: UUID format, context (not a plan type) — a4e0c908-daa0-4889-8883-4ef6589f1255-context.md → false"
  skip "T8: bare intent.md (no session-ID prefix) → false"
  skip "T9: partial UUID — a4e0c908-intent.md → false"
  skip "T10: 7-digit date prefix (wrong digit count) — 2026062-202454-intent.md → false"
  skip "T11: uppercase UUID — A4E0C908-DAA0-4889-8883-4EF6589F1255-intent.md → true (case-insensitive)"
  echo ""
  echo "=== Results ==="
  echo "0 passed, $SKIPS skipped (EXPECTED_FAIL — source not yet created), 0 failed."
  exit 0
fi

# Helper: call isPlanArtifact(basename) and compare to expected boolean string.
# $1 = description, $2 = input basename, $3 = expected ("true" or "false")
expect_artifact() {
  local desc="$1" input="$2" expected="$3"
  local result
  result=$(
    run_with_timeout node -e "
      const { isPlanArtifact } = require('$LIB');
      process.stdout.write(String(isPlanArtifact('$input')));
    " 2>&1
  )
  if [ "$result" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc — expected '$expected', got '$result'"
  fi
}

echo "=== isPlanArtifact tests ==="

# T1: Timestamp format, intent
expect_artifact \
  "T1: timestamp format, intent — 20260620-202454-intent.md → true" \
  "20260620-202454-intent.md" \
  "true"

# T2: Timestamp format, outline
expect_artifact \
  "T2: timestamp format, outline — 20260620-202454-outline.md → true" \
  "20260620-202454-outline.md" \
  "true"

# T3: Timestamp format, detail
expect_artifact \
  "T3: timestamp format, detail — 20260620-202454-detail.md → true" \
  "20260620-202454-detail.md" \
  "true"

# T4: UUID format, intent
expect_artifact \
  "T4: UUID format, intent — a4e0c908-daa0-4889-8883-4ef6589f1255-intent.md → true" \
  "a4e0c908-daa0-4889-8883-4ef6589f1255-intent.md" \
  "true"

# T5: UUID format, outline
expect_artifact \
  "T5: UUID format, outline — a4e0c908-daa0-4889-8883-4ef6589f1255-outline.md → true" \
  "a4e0c908-daa0-4889-8883-4ef6589f1255-outline.md" \
  "true"

# T6: UUID format, detail
expect_artifact \
  "T6: UUID format, detail — a4e0c908-daa0-4889-8883-4ef6589f1255-detail.md → true" \
  "a4e0c908-daa0-4889-8883-4ef6589f1255-detail.md" \
  "true"

# T7: UUID format, context (not a plan type) → false
expect_artifact \
  "T7: UUID format, context (not a plan type) — a4e0c908-daa0-4889-8883-4ef6589f1255-context.md → false" \
  "a4e0c908-daa0-4889-8883-4ef6589f1255-context.md" \
  "false"

# T8: Bare intent.md (no session-ID prefix) → false
expect_artifact \
  "T8: bare intent.md (no session-ID prefix) → false" \
  "intent.md" \
  "false"

# T9: Partial UUID — a4e0c908-intent.md → false
expect_artifact \
  "T9: partial UUID — a4e0c908-intent.md → false" \
  "a4e0c908-intent.md" \
  "false"

# T10: 7-digit date prefix (wrong digit count) → false
expect_artifact \
  "T10: 7-digit date prefix (wrong digit count) — 2026062-202454-intent.md → false" \
  "2026062-202454-intent.md" \
  "false"

# T11: Uppercase UUID → true (case-insensitive match)
expect_artifact \
  "T11: uppercase UUID — A4E0C908-DAA0-4889-8883-4EF6589F1255-intent.md → true" \
  "A4E0C908-DAA0-4889-8883-4EF6589F1255-intent.md" \
  "true"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed."
  exit 1
fi

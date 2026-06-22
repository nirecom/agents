#!/bin/bash
# Tests: bin/validate-hook-scope-concern
# Tags: hook-scope, auto-reject, codex-review, scope:issue-specific
#
# Unit tests for bin/validate-hook-scope-concern — the mechanical enforcement
# script that auto-rejects hook-scope codex concerns lacking a [verified: <files>]
# annotation.
#
# RED: this suite fails clean while bin/validate-hook-scope-concern is missing.
#
# L3 gap (what this test does NOT catch):
# - Whether run-codex-review-loop actually calls validate-hook-scope-concern
#   during a live codex session (requires a real codex exec + MCP session).
# Closest-to-action mitigation: integration is tested indirectly via the
# run-codex-review-loop invocation in the planning pipeline during normal
# workflow sessions; no dedicated L2 shim exists.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$AGENTS_DIR/bin/validate-hook-scope-concern"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$VALIDATOR" ]; then
  echo "FAIL: bin/validate-hook-scope-concern not found (implementation missing)"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$VALIDATOR" ]; then
  echo "FAIL: bin/validate-hook-scope-concern not executable"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

# V1: Non-hook concern → accepted
OUT=$("$VALIDATOR" "The plan is missing error handling for the config file." 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  pass "V1: non-hook concern accepted (exit 0)"
else
  fail "V1: non-hook concern accepted (rc=$RC out=$OUT)"
fi

# V2: enforce-issue-close keyword WITHOUT [verified:] → rejected
OUT=$("$VALIDATOR" "enforce-issue-close.js does not block this path." 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V2: enforce-issue-close without [verified:] → exit 1"
else
  fail "V2: enforce-issue-close without [verified:] → expected exit 1 (rc=$RC)"
fi

# V3: PreToolUse keyword WITHOUT [verified:] → rejected
OUT=$("$VALIDATOR" "This hook fires as PreToolUse on every Bash call." 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V3: PreToolUse without [verified:] → exit 1"
else
  fail "V3: PreToolUse without [verified:] → expected exit 1 (rc=$RC)"
fi

# V4: ISSUE_CLOSE_SKILL keyword WITHOUT [verified:] → rejected
OUT=$("$VALIDATOR" "ISSUE_CLOSE_SKILL=1 env var is not set here, so the hook blocks." 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V4: ISSUE_CLOSE_SKILL without [verified:] → exit 1"
else
  fail "V4: ISSUE_CLOSE_SKILL without [verified:] → expected exit 1 (rc=$RC)"
fi

# V5: command-head.js keyword WITHOUT [verified:] → rejected
OUT=$("$VALIDATOR" "command-head.js parses the command head differently than expected." 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V5: command-head.js without [verified:] → exit 1"
else
  fail "V5: command-head.js without [verified:] → expected exit 1 (rc=$RC)"
fi

# V6: enforce-issue-close WITH [verified: hooks/enforce-issue-close.js] → accepted
OUT=$("$VALIDATOR" "enforce-issue-close.js does not block this path. [verified: hooks/enforce-issue-close.js]" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  pass "V6: enforce-issue-close WITH [verified:] → exit 0"
else
  fail "V6: enforce-issue-close WITH [verified:] → expected exit 0 (rc=$RC out=$OUT)"
fi

# V7: PreToolUse WITH [verified: hooks/enforce-issue-close.js, hooks/lib/command-head.js] → accepted
OUT=$("$VALIDATOR" "PreToolUse fires on every tool call. [verified: hooks/enforce-issue-close.js, hooks/lib/command-head.js]" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  pass "V7: PreToolUse WITH [verified: multiple files] → exit 0"
else
  fail "V7: PreToolUse WITH [verified: multiple files] → expected exit 0 (rc=$RC out=$OUT)"
fi

# V8: ISSUE_CLOSE_SKILL WITH [verified: hooks/enforce-issue-close.js] → accepted
OUT=$("$VALIDATOR" "ISSUE_CLOSE_SKILL=1 bypasses the hook. [verified: hooks/enforce-issue-close.js]" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  pass "V8: ISSUE_CLOSE_SKILL WITH [verified:] → exit 0"
else
  fail "V8: ISSUE_CLOSE_SKILL WITH [verified:] → expected exit 0 (rc=$RC out=$OUT)"
fi

# V9: Empty [verified:] annotation (no files) → rejected
OUT=$("$VALIDATOR" "enforce-issue-close.js behavior is unclear. [verified: ]" 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V9: empty [verified: ] → exit 1"
else
  fail "V9: empty [verified: ] → expected exit 1 (rc=$RC out=$OUT)"
fi

# V10: stdin input — hook-scope without annotation → rejected
RC=0
OUT=$(echo "PreToolUse fires differently here." | "$VALIDATOR" 2>&1) || RC=$?
if [ "$RC" -eq 1 ]; then
  pass "V10: stdin hook-scope without [verified:] → exit 1"
else
  fail "V10: stdin hook-scope without [verified:] → expected exit 1 (rc=$RC)"
fi

# V11: stdin input — non-hook concern → accepted
RC=0
OUT=$(echo "The plan is missing a rollback step." | "$VALIDATOR" 2>&1) || RC=$?
if [ "$RC" -eq 0 ]; then
  pass "V11: stdin non-hook concern → exit 0"
else
  fail "V11: stdin non-hook concern → expected exit 0 (rc=$RC out=$OUT)"
fi

# V12: rejection message mentions the annotation format
OUT=$("$VALIDATOR" "enforce-issue-close.js does not block this." 2>&1); RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "verified"; then
  pass "V12: rejection message references [verified:] annotation"
else
  fail "V12: rejection message should reference [verified:] (rc=$RC out=$OUT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Tests for hooks/show-diff.js — isPlanDraftFile() suppression
# Verifies: drafts/ paths exit with no output (noopExit), non-drafts plans/ and
# unrelated paths still emit systemMessage.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_ROOT/hooks/show-diff.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Sanity: hook file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$HOOK" ]]; then
  echo "FATAL: hook not found: $HOOK"
  exit 1
fi

# ---------------------------------------------------------------------------
# Test A — /.claude/plans/drafts/ path → noopExit (stdout empty, exit 0)
# ---------------------------------------------------------------------------
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/home/user/.claude/plans/drafts/20260510-001819-detail-draft.md","content":"hello"}}'
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if [[ -z "$OUTPUT" ]]; then
  pass "show-diff: plans/drafts path → noopExit (no output)"
else
  fail "show-diff: plans/drafts path → unexpected output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test B — /.claude/plans/ (no drafts/) → systemMessage present
# ---------------------------------------------------------------------------
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/home/user/.claude/plans/20260510-001819-intent.md","content":"hello world"}}'
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if echo "$OUTPUT" | grep -q "systemMessage"; then
  pass "show-diff: plans/ (non-drafts) path → systemMessage shown"
else
  fail "show-diff: plans/ (non-drafts) path → no systemMessage. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test C — Windows backslash \.claude\plans\drafts\ path → noopExit
# ---------------------------------------------------------------------------
INPUT='{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\nire\\.claude\\plans\\drafts\\foo.md","content":"hello"}}'
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if [[ -z "$OUTPUT" ]]; then
  pass "show-diff: Windows backslash plans/drafts path → noopExit"
else
  fail "show-diff: Windows backslash plans/drafts path → unexpected output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test D — unrelated path → systemMessage present (existing behavior preserved)
# ---------------------------------------------------------------------------
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/home/user/projects/myapp/src/index.js","content":"console.log(1)"}}'
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if echo "$OUTPUT" | grep -q "systemMessage"; then
  pass "show-diff: non-plans path → systemMessage shown (existing behavior)"
else
  fail "show-diff: non-plans path → no systemMessage. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$ERRORS test(s) failed."
  exit 1
fi

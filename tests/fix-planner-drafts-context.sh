#!/usr/bin/env bash
# Tests for hooks/show-diff.js — isPlanFile() suppression
# Verifies: all ~/.workflow-plans/ paths exit with no output (noopExit),
# unrelated paths still emit systemMessage.
# Uses WORKFLOW_PLANS_DIR to control the resolved plans path deterministically.
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

# Resolve Node-visible home dir and set WORKFLOW_PLANS_DIR for deterministic testing
NODE_HOME="$(node -e "process.stdout.write(require('os').homedir().replace(/\\\\/g,'/'))")"
export WORKFLOW_PLANS_DIR="$NODE_HOME/.workflow-plans"
WIN_PLANS_DIR="$(echo "$WORKFLOW_PLANS_DIR" | sed 's|/|\\|g')"

# ---------------------------------------------------------------------------
# Test A — plans/drafts/ path → noopExit (stdout empty, exit 0)
# ---------------------------------------------------------------------------
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/drafts/20260510-001819-detail-draft.md\",\"content\":\"hello\"}}"
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if [[ -z "$OUTPUT" ]]; then
  pass "show-diff: plans/drafts path → noopExit (no output)"
else
  fail "show-diff: plans/drafts path → unexpected output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test B — plans/ (non-drafts, final artifact) → systemMessage shown
# Final artifacts (*-intent.md, *-outline.md, *-detail.md) are NOT suppressed;
# only drafts/ subdirectory files are suppressed.
# ---------------------------------------------------------------------------
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/20260510-001819-intent.md\",\"content\":\"hello world\"}}"
OUTPUT=$(echo "$INPUT" | node "$HOOK")
if echo "$OUTPUT" | grep -q "systemMessage"; then
  pass "show-diff: plans/ (non-drafts) final artifact → systemMessage shown"
else
  fail "show-diff: plans/ (non-drafts) final artifact → expected systemMessage, got: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Test C — Windows backslash plans\drafts\ path → noopExit
# ---------------------------------------------------------------------------
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${WIN_PLANS_DIR}\\\\drafts\\\\foo.md\",\"content\":\"hello\"}}"
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

#!/usr/bin/env bash
# Tests for isPlanFile detection in hooks/show-diff.js.
#
# These tests assert the CORRECT POST-FIX behavior (isPlanFile, checking
# /.claude/plans/ broadly).  Before the fix (isPlanDraftFile, narrow check),
# T1 / T3 / T6 will FAIL — that is expected and proves the fix is needed.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-diff.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# Asserts stdout is empty (noop — plan file detected or non-watched tool)
expect_empty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected empty stdout, got: $result"
  fi
}

# Asserts stdout is non-empty (diff shown)
expect_nonempty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -n "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected non-empty stdout (diff), got empty"
  fi
}

# ── T1: POSIX path under /.claude/plans/ (non-drafts) ────────────────────────
# Post-fix: noop.  Pre-fix: FAIL (isPlanDraftFile misses this path).
echo "=== T1: /.claude/plans/foo-intent.md ==="
expect_empty "T1 plan intent file is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"/.claude/plans/foo-intent.md","content":"x"}}'

# ── T2: POSIX path under /.claude/plans/drafts/ ──────────────────────────────
# Already working before the fix (narrow check covers drafts).
echo "=== T2: /.claude/plans/drafts/foo.md ==="
expect_empty "T2 plan drafts file is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"/.claude/plans/drafts/foo.md","content":"x"}}'

# ── T3: POSIX path — date-stamped detail plan ────────────────────────────────
# Post-fix: noop.  Pre-fix: FAIL (isPlanDraftFile misses non-drafts subpath).
echo "=== T3: /.claude/plans/20260512-issues-migration-detail.md ==="
expect_empty "T3 date-stamped detail plan is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"/.claude/plans/20260512-issues-migration-detail.md","content":"x"}}'

# ── T4: plans-archive (similar prefix but NOT /.claude/plans/) ───────────────
# Not a plan file — diff should be shown.
echo "=== T4: /.claude/plans-archive/foo.md ==="
expect_nonempty "T4 plans-archive path shows diff" \
  '{"tool_name":"Write","tool_input":{"file_path":"/.claude/plans-archive/foo.md","content":"x"}}'

# ── T5: /src/plans/foo.md (no .claude prefix) ────────────────────────────────
# Not a plan file — diff should be shown.
echo "=== T5: /src/plans/foo.md ==="
expect_nonempty "T5 src/plans path shows diff" \
  '{"tool_name":"Write","tool_input":{"file_path":"/src/plans/foo.md","content":"x"}}'

# ── T6: Windows backslash path under .claude\plans\ ─────────────────────────
# Post-fix: noop (backslashes normalized to /). Pre-fix: FAIL.
echo "=== T6: C:\\Users\\user\\.claude\\plans\\foo.md (Windows path) ==="
expect_empty "T6 Windows plans path is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\user\\.claude\\plans\\foo.md","content":"x"}}'

# ── T7: Windows backslash path under .claude\plans\drafts\ ──────────────────
# Already working before fix.
echo "=== T7: C:\\Users\\user\\.claude\\plans\\drafts\\bar.md (Windows path) ==="
expect_empty "T7 Windows plans/drafts path is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\user\\.claude\\plans\\drafts\\bar.md","content":"x"}}'

# ── T8: Empty file_path ───────────────────────────────────────────────────────
# Hook should early-return (noop) for empty path.
echo "=== T8: empty file_path ==="
expect_empty "T8 empty file_path is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"","content":"x"}}'

# ── T9: Non-watched tool (Bash) ───────────────────────────────────────────────
# Hook only watches Write/Edit/MultiEdit/editFiles — Bash is ignored.
echo "=== T9: Bash tool (non-watched) ==="
expect_empty "T9 Bash tool is noop" \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

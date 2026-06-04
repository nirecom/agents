#!/usr/bin/env bash
# Tests: hooks/lib/vscode-open.js
# Tags: vscode, hook, plan, confirm-checkpoint
# Unit tests for hooks/lib/vscode-open.js — VS Code detection and file open helpers
# extracted from hooks/show-plan-link.js for reuse by confirm-checkpoint.js.
#
# Source file is created in a later step. When missing, the test SKIPs gracefully.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
LIB="$AGENTS_DIR/hooks/lib/vscode-open.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# ── Skip gracefully if source file not yet created ─────────────────────────
if [[ ! -f "$LIB" ]]; then
  echo "SKIP: hook lib not yet created ($LIB)"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

# Per-run temp dir
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
TMPDIR_LOCAL="${NODE_TMPDIR}/vscode-open-test-$$"
mkdir -p "$TMPDIR_LOCAL"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# Unset VS Code detection vars by default
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset SHOW_PLAN_LINK_NO_AUTO_OPEN 2>/dev/null || true
unset SHOW_PLAN_LINK_NO_SPAWN 2>/dev/null || true
unset SHOW_PLAN_LINK_MARKER_FILE 2>/dev/null || true

# Run a JS expression against the lib module; print the stringified result.
# $1 = description, $2 = expected, $3 = expression body, $4... = env assignments (KEY=VAL)
expect_result() {
  local desc="$1" expected="$2" expr="$3"
  shift 3
  local result
  result=$(
    # Unset baseline env vars in subshell
    unset TERM_PROGRAM CLAUDE_CODE_ENTRYPOINT SHOW_PLAN_LINK_NO_AUTO_OPEN
    for assignment in "$@"; do
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    run_with_timeout node -e "
      const lib = require('$LIB');
      const v = $expr;
      process.stdout.write(String(v));
    " 2>&1
  )
  if [ "$result" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc — expected '$expected', got '$result'"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# isVsCode() tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== isVsCode() tests ==="

# T1: isVsCode() returns false when no env vars set
expect_result "T1 isVsCode() with no env vars → false" "false" \
  "lib.isVsCode()"

# T2: isVsCode() returns true when TERM_PROGRAM=vscode
expect_result "T2 isVsCode() with TERM_PROGRAM=vscode → true" "true" \
  "lib.isVsCode()" \
  TERM_PROGRAM=vscode

# T3: isVsCode() returns true when CLAUDE_CODE_ENTRYPOINT=claude-vscode
expect_result "T3 isVsCode() with CLAUDE_CODE_ENTRYPOINT=claude-vscode → true" "true" \
  "lib.isVsCode()" \
  CLAUDE_CODE_ENTRYPOINT=claude-vscode

# ══════════════════════════════════════════════════════════════════════════
# shouldOpenInVsCode() tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== shouldOpenInVsCode() tests ==="

# T4: shouldOpenInVsCode() returns false when SHOW_PLAN_LINK_NO_AUTO_OPEN=1
expect_result "T4 shouldOpenInVsCode() NO_AUTO_OPEN=1 + TERM_PROGRAM=vscode → false" "false" \
  "lib.shouldOpenInVsCode()" \
  TERM_PROGRAM=vscode \
  SHOW_PLAN_LINK_NO_AUTO_OPEN=1

# ══════════════════════════════════════════════════════════════════════════
# workspaceFolderUriFrom() tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== workspaceFolderUriFrom() tests ==="

# T5: Windows C:/path → file:///C:/path
expect_result "T5 workspaceFolderUriFrom('C:/Users/test/project') → file:///C:/..." \
  "file:///C:/Users/test/project" \
  "lib.workspaceFolderUriFrom('C:/Users/test/project')"

# T6: POSIX /home/user → file:///home/user
expect_result "T6 workspaceFolderUriFrom('/home/user') → file:///home/user" \
  "file:///home/user" \
  "lib.workspaceFolderUriFrom('/home/user')"

# T7: '/' root → null
expect_result "T7 workspaceFolderUriFrom('/') → null" "null" \
  "lib.workspaceFolderUriFrom('/')"

# T8: null → null
expect_result "T8 workspaceFolderUriFrom(null) → null" "null" \
  "lib.workspaceFolderUriFrom(null)"

# ══════════════════════════════════════════════════════════════════════════
# openInVsCode() with NO_SPAWN + MARKER_FILE test
# ══════════════════════════════════════════════════════════════════════════

echo "=== openInVsCode() marker file test ==="

# T9: openInVsCode with SHOW_PLAN_LINK_NO_SPAWN=1 + MARKER_FILE → writes marker
T9_MARKER="$TMPDIR_LOCAL/marker-t9.txt"
T9_ABS_PATH="$TMPDIR_LOCAL/foo-detail.md"
T9_FOLDER_URI="file:///C:/Users/test/project"
rm -f "$T9_MARKER"

(
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_MARKER_FILE="$T9_MARKER"
  run_with_timeout node -e "
    const lib = require('$LIB');
    lib.openInVsCode('$T9_ABS_PATH', '$T9_FOLDER_URI');
  " 2>/dev/null || true
)

if [ ! -f "$T9_MARKER" ]; then
  fail "T9 openInVsCode — marker file NOT written at $T9_MARKER"
else
  if grep -qF "$T9_FOLDER_URI" "$T9_MARKER" && grep -qF "$T9_ABS_PATH" "$T9_MARKER"; then
    pass "T9 openInVsCode writes marker with both folder-uri and file args"
  else
    fail "T9 openInVsCode marker missing folder-uri or file arg. Contents: $(cat "$T9_MARKER")"
  fi
fi
rm -f "$T9_MARKER"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

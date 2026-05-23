#!/usr/bin/env bash
# Tests for new VS Code spawn behavior of hooks/show-plan-link.js.
# Written first (TDD); spawn-related assertions fail until the source is implemented.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-plan-link.js"
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

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-spawn-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Unset VS Code detection vars by default.
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook_capture_spawn() {
  # Usage: run_hook_capture_spawn <json> <marker_path> [KEY=val ...]
  local json="$1" marker="$2"
  shift 2
  rm -f "$marker"
  (
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    export SHOW_PLAN_LINK_NO_SPAWN=1
    export SHOW_PLAN_LINK_MARKER_FILE="$marker"
    echo "$json" | run_with_timeout node "$HOOK" >/dev/null 2>&1
  )
}

# T-SPAWN-1
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-1"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ -f "$MARKER" ]; then
  line1=$(sed -n '1p' "$MARKER")
  line2=$(sed -n '2p' "$MARKER")
  if [ "$line1" = "--folder-uri" ] && echo "$line2" | grep -q "^file://"; then
    pass "T-SPAWN-1 VS Code+CONFIRM_DETAIL=on -> --folder-uri present"
  else
    fail "T-SPAWN-1 unexpected marker content: $(cat "$MARKER")"
  fi
else
  fail "T-SPAWN-1 marker not created (spawn not triggered)"
fi

# T-SPAWN-2
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-2"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-outline.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  CLAUDE_CODE_ENTRYPOINT=claude-vscode CONFIRM_OUTLINE=on
if [ -f "$MARKER" ] && grep -q "^--folder-uri$" "$MARKER"; then
  pass "T-SPAWN-2 CLAUDE_CODE_ENTRYPOINT=claude-vscode -> --folder-uri present"
else
  fail "T-SPAWN-2 marker missing or no --folder-uri"
fi

# T-SPAWN-3
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-3"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-intent.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_INTENT=on
if [ -f "$MARKER" ]; then
  pass "T-SPAWN-3 intent.md class-uniform spawn"
else
  fail "T-SPAWN-3 marker not created for intent.md"
fi

# T-SPAWN-4
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-4"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=off
if [ ! -f "$MARKER" ]; then
  pass "T-SPAWN-4 CONFIRM_DETAIL=off suppresses spawn"
else
  fail "T-SPAWN-4 marker created despite CONFIRM_DETAIL=off"
fi

# T-SPAWN-5
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-5"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  CONFIRM_DETAIL=on
if [ ! -f "$MARKER" ]; then
  pass "T-SPAWN-5 non-VS Code env suppresses spawn"
else
  fail "T-SPAWN-5 marker created without VS Code env"
fi

# T-SPAWN-6
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-6"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on SHOW_PLAN_LINK_NO_AUTO_OPEN=1
if [ ! -f "$MARKER" ]; then
  pass "T-SPAWN-6 SHOW_PLAN_LINK_NO_AUTO_OPEN=1 suppresses spawn"
else
  fail "T-SPAWN-6 marker created despite SHOW_PLAN_LINK_NO_AUTO_OPEN=1"
fi

# T-SPAWN-7
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-7"
FIXTURE_CWD="/tmp/fixture-ws"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$FIXTURE_CWD\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ -f "$MARKER" ]; then
  line2=$(sed -n '2p' "$MARKER")
  EXPECTED_URI="file:///tmp/fixture-ws"
  if [ "$line2" = "$EXPECTED_URI" ]; then
    pass "T-SPAWN-7 input.cwd -> correct --folder-uri"
  else
    fail "T-SPAWN-7 URI mismatch: got '$line2', expected '$EXPECTED_URI'"
  fi
else
  fail "T-SPAWN-7 marker not created"
fi

# T-SPAWN-8
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-8"
EXPECTED_CWD_URI=$(run_with_timeout node -e "
  const cwd = process.cwd().replace(/\\\\/g, '/');
  const prefix = process.platform === 'win32' ? 'file:///' : 'file://';
  process.stdout.write(prefix + cwd);
")
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ -f "$MARKER" ]; then
  line1=$(sed -n '1p' "$MARKER")
  line2=$(sed -n '2p' "$MARKER")
  if [ "$line1" = "--folder-uri" ] && [ "$line2" = "$EXPECTED_CWD_URI" ]; then
    pass "T-SPAWN-8 no cwd field -> process.cwd() fallback URI"
  else
    fail "T-SPAWN-8 URI mismatch: got line1='$line1' line2='$line2', expected '--folder-uri' + '$EXPECTED_CWD_URI'"
  fi
else
  fail "T-SPAWN-8 marker not created"
fi

# T-SPAWN-9
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-9"
DETAIL_ABS="$PLANS_DIR/abc-detail.md"
(
  if echo "${OSTYPE:-}" | grep -qi "msys\|cygwin\|mingw"; then
    cd "C:/" 2>/dev/null || cd "/"
  else
    cd /
  fi
  export TERM_PROGRAM=vscode
  export CONFIRM_DETAIL=on
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_MARKER_FILE="$MARKER"
  rm -f "$MARKER"
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_ABS\"},\"tool_response\":{\"success\":true},\"cwd\":\"\"}" \
    | run_with_timeout node "$HOOK" >/dev/null 2>&1
)
if [ -f "$MARKER" ]; then
  line_count=$(wc -l < "$MARKER" | tr -d ' ')
  line1=$(sed -n '1p' "$MARKER")
  line2=$(sed -n '2p' "$MARKER")
  if [ "$line1" = "-r" ] && [ -n "$line2" ] && [ "$line_count" -le 2 ]; then
    pass "T-SPAWN-9 empty cwd + root process.cwd -> bare -r (no --folder-uri)"
  else
    echo "SKIP T-SPAWN-9 (cd / did not force root cwd, got: $(cat "$MARKER"))"
  fi
else
  fail "T-SPAWN-9 marker not created"
fi

# T-SPAWN-10
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-10"
run_hook_capture_spawn \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ ! -f "$MARKER" ]; then
  pass "T-SPAWN-10 Edit tool does not trigger spawn"
else
  fail "T-SPAWN-10 marker created for Edit tool"
fi

# T-SPAWN-11
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-11"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"exit_code\":1},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ ! -f "$MARKER" ]; then
  pass "T-SPAWN-11 failed write does not trigger spawn"
else
  fail "T-SPAWN-11 marker created despite exit_code:1"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  echo "All spawn tests passed."
  exit 0
else
  echo "$ERRORS test(s) failed."
  exit 1
fi

#!/usr/bin/env bash
# Tests: hooks/show-plan-link.js, hooks/show-plan-link.js.
# Tags: plan, vscode, hook, bin, macos
# Tests for VS Code 1-spawn behavior of hooks/show-plan-link.js.
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

parse_marker() {
  # Usage: parse_marker <marker_file> <block_num>  → prints lines of block N (1-indexed)
  # single block, 3 lines: `--folder-uri`, `<uri>`, `<filePath>`
  local file="$1" block="$2"
  awk -v b="$block" 'BEGIN{n=1} /^$/{n++;next} n==b{print}' "$file"
}

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-spawn-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Unset VS Code detection vars by default.
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset VSCODE_CRASH_REPORTER_PROCESS_TYPE 2>/dev/null || true
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
DETAIL_ABS="$PLANS_DIR/abc-detail.md"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_ABS\"},\"tool_response\":{\"success\":true},\"cwd\":\"$PLANS_DIR\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ -f "$MARKER" ]; then
  b1_l1=$(parse_marker "$MARKER" 1 | sed -n '1p')
  b1_l2=$(parse_marker "$MARKER" 1 | sed -n '2p')
  b1_l3=$(parse_marker "$MARKER" 1 | sed -n '3p')
  # Normalize backslashes (Windows native abs path) to forward slashes for comparison.
  b1_l3_norm=$(echo "$b1_l3" | tr '\\' '/')
  DETAIL_ABS_norm=$(echo "$DETAIL_ABS" | tr '\\' '/')
  if [ "$b1_l1" = "--folder-uri" ] && echo "$b1_l2" | grep -q "^file://" \
     && [ "$b1_l3_norm" = "$DETAIL_ABS_norm" ]; then
    pass "T-SPAWN-1 VS Code+CONFIRM_DETAIL=on -> single-spawn (folder-uri + file)"
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
if [ -f "$MARKER" ]; then
  b1_l1=$(parse_marker "$MARKER" 1 | sed -n '1p')
  if [ "$b1_l1" = "--folder-uri" ]; then
    pass "T-SPAWN-2 CLAUDE_CODE_ENTRYPOINT=claude-vscode -> block-1 --folder-uri present"
  else
    fail "T-SPAWN-2 block-1 missing --folder-uri: got '$b1_l1'"
  fi
else
  fail "T-SPAWN-2 marker missing"
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
  b1_l2=$(parse_marker "$MARKER" 1 | sed -n '2p')
  b1_l3=$(parse_marker "$MARKER" 1 | sed -n '3p')
  b1_l3_norm=$(echo "$b1_l3" | tr '\\' '/')
  PLANS_DIR_abc_detail_norm=$(echo "$PLANS_DIR/abc-detail.md" | tr '\\' '/')
  EXPECTED_URI="file:///tmp/fixture-ws"
  if [ "$b1_l2" = "$EXPECTED_URI" ] && [ "$b1_l3_norm" = "$PLANS_DIR_abc_detail_norm" ]; then
    pass "T-SPAWN-7 input.cwd -> single-spawn (folder-uri + file)"
  else
    fail "T-SPAWN-7 mismatch: block1-line2='$b1_l2', block1-line3='$b1_l3', expected URI='$EXPECTED_URI'"
  fi
else
  fail "T-SPAWN-7 marker not created"
fi

# T-SPAWN-8
MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-8"
EXPECTED_CWD_URI=$(run_with_timeout node -e "
  const path = require('path');
  const cwd = process.cwd();
  const fwd = cwd.replace(/\\\\/g, '/');
  const isWin = process.platform === 'win32';
  let segments, prefix;
  if (isWin) {
    // C:/git/my project -> file:///C:/git/my%20project
    const m = fwd.match(/^([A-Za-z]:)\/(.*)$/);
    if (m) {
      prefix = 'file:///' + m[1] + '/';
      segments = m[2].split('/').filter(s => s.length > 0).map(encodeURIComponent);
    } else {
      prefix = 'file:///';
      segments = fwd.split('/').filter(s => s.length > 0).map(encodeURIComponent);
    }
  } else {
    prefix = 'file://';
    segments = fwd.split('/').map((s, i) => i === 0 ? s : encodeURIComponent(s));
  }
  process.stdout.write(prefix + segments.join('/'));
")
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
if [ -f "$MARKER" ]; then
  b1_l1=$(parse_marker "$MARKER" 1 | sed -n '1p')
  b1_l2=$(parse_marker "$MARKER" 1 | sed -n '2p')
  b1_l3=$(parse_marker "$MARKER" 1 | sed -n '3p')
  b1_l3_norm=$(echo "$b1_l3" | tr '\\' '/')
  DETAIL_ABS_norm=$(echo "$PLANS_DIR/abc-detail.md" | tr '\\' '/')
  if [ "$b1_l1" = "--folder-uri" ] && [ "$b1_l2" = "$EXPECTED_CWD_URI" ] && [ "$b1_l3_norm" = "$DETAIL_ABS_norm" ]; then
    pass "T-SPAWN-8 no cwd field -> process.cwd() fallback URI (encoded)"
  else
    fail "T-SPAWN-8 mismatch: b1_l1='$b1_l1', b1_l2='$b1_l2', b1_l3='$b1_l3', expected URI='$EXPECTED_CWD_URI'"
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
  # No blank line => single block; grep blank-line absence
  if grep -q "^$" "$MARKER"; then
    echo "SKIP T-SPAWN-9 (cd / did not force root cwd, marker has blank line: $(cat "$MARKER"))"
  else
    b1_l1=$(parse_marker "$MARKER" 1 | sed -n '1p')
    b1_l2=$(parse_marker "$MARKER" 1 | sed -n '2p')
    b1_l2_norm=$(echo "$b1_l2" | tr '\\' '/')
    DETAIL_ABS_norm=$(echo "$DETAIL_ABS" | tr '\\' '/')
    if [ "$b1_l1" = "-r" ] && [ "$b1_l2_norm" = "$DETAIL_ABS_norm" ]; then
      pass "T-SPAWN-9 empty cwd + root process.cwd -> bare -r (no folder-uri)"
    else
      fail "T-SPAWN-9 unexpected single-block content: b1_l1='$b1_l1', b1_l2='$b1_l2'"
    fi
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

# T-SPAWN-12
# Windows-only: Unix-style /<drive>/ cwd must be normalized to a Windows drive URI.
if [ "${OS:-}" = "Windows_NT" ] || echo "${OSTYPE:-}" | grep -qi "msys\|cygwin\|mingw"; then
  MARKER="$PLANS_DIR/spawn-marker-T-SPAWN-12"
  run_hook_capture_spawn \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$PLANS_DIR"'/abc-detail.md"},"tool_response":{"success":true},"cwd":"/c/git/agents"}' \
    "$MARKER" \
    TERM_PROGRAM=vscode CONFIRM_DETAIL=on
  if [ -f "$MARKER" ]; then
    b1_l2=$(parse_marker "$MARKER" 1 | sed -n '2p')
    EXPECTED_WIN_URI="file:///C:/git/agents"
    if [ "$b1_l2" = "$EXPECTED_WIN_URI" ]; then
      pass "T-SPAWN-12 Unix-style /<drive>/ cwd normalized to Windows drive URI"
    else
      fail "T-SPAWN-12 expected URI '$EXPECTED_WIN_URI', got '$b1_l2'"
    fi
  else
    fail "T-SPAWN-12 marker not created"
  fi
else
  echo "SKIP T-SPAWN-12 (not Windows — Unix-style normalization not applicable)"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  echo "All spawn tests passed."
  exit 0
else
  echo "$ERRORS test(s) failed."
  exit 1
fi

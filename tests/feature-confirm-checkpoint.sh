#!/usr/bin/env bash
# Tests: hooks/confirm-checkpoint.js, hooks/lib/turn-marker.js
# Tags: confirm-checkpoint, hook, plan, sentinel, workflow
# Tests for hooks/confirm-checkpoint.js — PreToolUse hook detecting
# WORKFLOW_CONFIRM_INTENT / OUTLINE / DETAIL / PR_CREATED sentinels in Bash commands.
#
# Source files (hooks/confirm-checkpoint.js, hooks/lib/turn-marker.js::peekTurnMarkers)
# are created in later steps. When missing, the test SKIPs gracefully.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
HOOK="$AGENTS_DIR/hooks/confirm-checkpoint.js"
TURN_MARKER_LIB="$AGENTS_DIR/hooks/lib/turn-marker.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# ── Skip gracefully if source file not yet created ─────────────────────────
if [[ ! -f "$HOOK" ]]; then
  echo "SKIP: hook not yet created ($HOOK)"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

# Skip if peekTurnMarkers is not yet exported from turn-marker.js
HAS_PEEK=$(run_with_timeout node -e "
  try {
    const tm = require('$TURN_MARKER_LIB');
    process.stdout.write(typeof tm.peekTurnMarkers === 'function' ? '1' : '0');
  } catch (e) { process.stdout.write('0'); }
" 2>/dev/null)
if [ "$HAS_PEEK" != "1" ]; then
  echo "SKIP: turn-marker.js peekTurnMarkers not yet exported"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

# Per-run temp dirs
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/ccp-plans-$$"
WORKFLOW_DIR_TEST="${NODE_TMPDIR}/ccp-workflow-$$"
mkdir -p "$PLANS_DIR" "$WORKFLOW_DIR_TEST"

ISOLATED_CFG_DIR="${NODE_TMPDIR}/ccp-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_TEST"

trap 'rm -rf "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$ISOLATED_CFG_DIR"' EXIT

# Unset CONFIRM_* by default
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
# Test mode: don't actually open VS Code / browser
export SHOW_PLAN_LINK_NO_SPAWN=1
export SHOW_USER_VERIFIED_NO_SPAWN=1
export TERM_PROGRAM=vscode  # ensures the hook tries to open (so we can verify the no-spawn marker path)

SID="test-ccp-$$"

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

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

# Returns the .systemMessage value of a hook output JSON, or empty string.
extract_system_message() {
  local result="$1"
  echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null
}

expect_contains() {
  local desc="$1" json="$2" expected="$3"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  local msg
  msg=$(extract_system_message "$result")
  if echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage missing '$expected': $msg"
  fi
}

# Build PreToolUse-style JSON payload for a Bash command sentinel.
# $1 = command string (must be JSON-escape-safe — no quotes inside)
make_bash_json() {
  local cmd="$1"
  run_with_timeout node -e "
    process.stdout.write(JSON.stringify({
      tool_name: 'Bash',
      tool_input: { command: process.argv[1] },
      session_id: '$SID',
      transcript_path: '/tmp/nope.jsonl'
    }));
  " "$cmd"
}

# Write a turn marker file for the session, with given suffix and absPath.
# Uses writeTurnMarker if available; falls back to direct write.
write_marker() {
  local suffix="$1" absPath="$2"
  run_with_timeout node -e "
    const tm = require('$TURN_MARKER_LIB');
    tm.writeTurnMarker('$SID', {
      absPath: '$absPath',
      suffix: '$suffix',
      ts: Date.now(),
      created_at: new Date().toISOString()
    });
  " 2>/dev/null
}

clear_markers() {
  # Clean up markers between tests
  rm -f "$WORKFLOW_DIR_TEST/$SID".confirm-plan-turn-*.json 2>/dev/null || true
}

# ── T1: non-Bash tool_name → empty stdout, exit 0 ──────────────────────────
echo "=== T1: non-Bash tool_name (Write) ==="
expect_empty "T1 non-Bash tool → noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/foo.md\"},\"session_id\":\"$SID\"}"

# ── T2: Bash without sentinel → empty stdout, exit 0 ────────────────────────
echo "=== T2: Bash without sentinel ==="
clear_markers
T2_JSON=$(make_bash_json "echo hello")
expect_empty "T2 Bash without sentinel → noop" "$T2_JSON"

# ── T3: WORKFLOW_CONFIRM_INTENT + turn marker → systemMessage with abs path ─
echo "=== T3: CONFIRM_INTENT + turn marker present ==="
clear_markers
T3_ABS="$PLANS_DIR/sess-abc-intent.md"
touch "$T3_ABS"
write_marker "intent" "$T3_ABS"
T3_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")
T3_OUT=$(run_hook "$T3_JSON")
T3_MSG=$(extract_system_message "$T3_OUT")
if echo "$T3_MSG" | grep -qF "$T3_ABS"; then
  pass "T3 systemMessage contains absPath from turn marker"
else
  fail "T3 systemMessage missing absPath $T3_ABS — got: $T3_MSG"
fi
if echo "$T3_MSG" | grep -qF "[intent]"; then
  pass "T3 systemMessage contains [intent] prefix"
else
  fail "T3 systemMessage missing [intent] prefix — got: $T3_MSG"
fi
clear_markers

# ── T4: CONFIRM_INTENT + no marker, PLANS_DIR file exists ───────────────────
echo "=== T4: CONFIRM_INTENT + no marker + PLANS_DIR file ==="
clear_markers
T4_ABS="$PLANS_DIR/$SID-intent.md"
touch "$T4_ABS"
T4_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")
T4_OUT=$(run_hook "$T4_JSON")
T4_MSG=$(extract_system_message "$T4_OUT")
if echo "$T4_MSG" | grep -qF "$T4_ABS" || echo "$T4_MSG" | grep -qF "$SID-intent.md"; then
  pass "T4 systemMessage references PLANS_DIR file"
else
  fail "T4 systemMessage missing PLANS_DIR file path — got: $T4_MSG"
fi
rm -f "$T4_ABS"

# ── T5: CONFIRM_INTENT + neither marker nor file → systemMessage w/o path ──
echo "=== T5: CONFIRM_INTENT + neither marker nor file ==="
clear_markers
T5_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")
T5_OUT=$(run_hook "$T5_JSON")
T5_MSG=$(extract_system_message "$T5_OUT")
if [ -z "$T5_MSG" ]; then
  fail "T5 expected systemMessage with Click Allow text, got empty"
elif echo "$T5_MSG" | grep -qF "Click Allow"; then
  pass "T5 systemMessage has Click Allow even without file path"
else
  fail "T5 systemMessage missing 'Click Allow' — got: $T5_MSG"
fi

# ── T6: WORKFLOW_CONFIRM_OUTLINE sentinel → [outline] prefix ────────────────
echo "=== T6: WORKFLOW_CONFIRM_OUTLINE ==="
clear_markers
T6_ABS="$PLANS_DIR/sess-outline-test-outline.md"
touch "$T6_ABS"
write_marker "outline" "$T6_ABS"
T6_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_OUTLINE>>\"")
T6_OUT=$(run_hook "$T6_JSON")
T6_MSG=$(extract_system_message "$T6_OUT")
if echo "$T6_MSG" | grep -qF "[outline]"; then
  pass "T6 systemMessage contains [outline] prefix"
else
  fail "T6 systemMessage missing [outline] prefix — got: $T6_MSG"
fi
clear_markers

# ── T7: WORKFLOW_CONFIRM_DETAIL sentinel → [detail] prefix ──────────────────
echo "=== T7: WORKFLOW_CONFIRM_DETAIL ==="
clear_markers
T7_ABS="$PLANS_DIR/sess-detail-test-detail.md"
touch "$T7_ABS"
write_marker "detail" "$T7_ABS"
T7_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_DETAIL>>\"")
T7_OUT=$(run_hook "$T7_JSON")
T7_MSG=$(extract_system_message "$T7_OUT")
if echo "$T7_MSG" | grep -qF "[detail]"; then
  pass "T7 systemMessage contains [detail] prefix"
else
  fail "T7 systemMessage missing [detail] prefix — got: $T7_MSG"
fi
clear_markers

# ── T8: WORKFLOW_CONFIRM_PR_CREATED: <url> with /pull/<N> ──────────────────
echo "=== T8: WORKFLOW_CONFIRM_PR_CREATED with PR URL ==="
T8_URL="https://github.com/user/repo/pull/42"
T8_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_PR_CREATED: $T8_URL>>\"")
T8_OUT=$(run_hook "$T8_JSON")
T8_MSG=$(extract_system_message "$T8_OUT")
if echo "$T8_MSG" | grep -qF "PR #42 created" && echo "$T8_MSG" | grep -qF "$T8_URL"; then
  pass "T8 systemMessage contains 'PR #42 created' and URL"
else
  fail "T8 systemMessage missing PR# or URL — got: $T8_MSG"
fi
if echo "$T8_MSG" | grep -qF "Click Allow"; then
  pass "T8 systemMessage contains 'Click Allow'"
else
  fail "T8 systemMessage missing 'Click Allow' — got: $T8_MSG"
fi

# ── T9: CONFIRM_OUTLINE=off → "[confirm-skipped: CONFIRM_OUTLINE=off]" ─────
echo "=== T9: CONFIRM_OUTLINE=off → skipped systemMessage ==="
clear_markers
T9_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_OUTLINE>>\"")
T9_OUT=$(
  export CONFIRM_OUTLINE=off
  echo "$T9_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T9_MSG=$(extract_system_message "$T9_OUT")
if echo "$T9_MSG" | grep -qF "[confirm-skipped: CONFIRM_OUTLINE=off]"; then
  pass "T9 CONFIRM_OUTLINE=off → '[confirm-skipped: CONFIRM_OUTLINE=off]'"
else
  fail "T9 CONFIRM_OUTLINE=off — missing expected skipped message: $T9_MSG"
fi

# ── T10: systemMessage always contains "Click Allow to proceed, Deny to abort." (plan ON) ──
echo "=== T10: 'Click Allow' tagline on plan stage (ON) ==="
clear_markers
T10_ABS="$PLANS_DIR/sess-t10-detail.md"
touch "$T10_ABS"
write_marker "detail" "$T10_ABS"
T10_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_DETAIL>>\"")
T10_OUT=$(run_hook "$T10_JSON")
T10_MSG=$(extract_system_message "$T10_OUT")
if echo "$T10_MSG" | grep -qF "Click Allow to proceed, Deny to abort."; then
  pass "T10 plan ON path has 'Click Allow to proceed, Deny to abort.'"
else
  fail "T10 missing 'Click Allow to proceed, Deny to abort.' — got: $T10_MSG"
fi
clear_markers

# ── T11: PR_CREATED with non-github.com URL → ignored (security: reject non-PR URLs) ─
echo "=== T11: PR_CREATED non-github.com/pull/N URL is ignored ==="
T11_URL="https://evil.example.com/not/a/pr"
T11_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_PR_CREATED: $T11_URL>>\"")
T11_OUT=$(run_hook "$T11_JSON")
T11_MSG=$(extract_system_message "$T11_OUT")
if [ -z "$T11_MSG" ]; then
  pass "T11 PR_CREATED non-github.com/pull/N URL is ignored (no systemMessage)"
else
  fail "T11 PR_CREATED non-github.com/pull/N URL should be ignored, got: $T11_MSG"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

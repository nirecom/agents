#!/usr/bin/env bash
# Tests: hooks/pr-created-open.js
# Tags: pr-created-open, hook, pr, github
# Tests for hooks/pr-created-open.js — PostToolUse hook detecting `gh pr create`
# completion and emitting a systemMessage with the PR URL.
#
# Source file is created in a later step. When missing, the test SKIPs gracefully.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
HOOK="$AGENTS_DIR/hooks/pr-created-open.js"
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

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
ISOLATED_CFG_DIR="${NODE_TMPDIR}/prco-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
trap 'rm -rf "$ISOLATED_CFG_DIR"' EXIT

# Test mode: don't actually open browser
export SHOW_USER_VERIFIED_NO_SPAWN=1
export PR_CREATED_OPEN_NO_BROWSER=1  # unused — no such env var in the hook; kept as marker for future opt-out
export SHOW_USER_VERIFIED_NO_BROWSER=1

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

extract_system_message() {
  local result="$1"
  echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null
}

# Build a PostToolUse-style JSON payload via node to avoid shell escaping.
# $1 = tool_name, $2 = command, $3 = exit_code, $4 = stdout
make_json() {
  local tool_name="$1" cmd="$2" exit_code="$3" stdout_val="$4"
  run_with_timeout node -e "
    process.stdout.write(JSON.stringify({
      tool_name: process.argv[1],
      tool_input: { command: process.argv[2] },
      tool_response: {
        stdout: process.argv[4],
        exit_code: parseInt(process.argv[3], 10)
      }
    }));
  " "$tool_name" "$cmd" "$exit_code" "$stdout_val"
}

# ── T1: non-Bash tool_name → empty stdout, exit 0 ──────────────────────────
echo "=== T1: non-Bash tool_name ==="
T1_JSON=$(make_json "Write" "gh pr create" "0" "https://github.com/user/repo/pull/42")
expect_empty "T1 non-Bash tool_name → noop" "$T1_JSON"

# ── T2: Bash without "gh pr create" → empty stdout, exit 0 ──────────────────
echo "=== T2: Bash without gh pr create ==="
T2_JSON=$(make_json "Bash" "echo hello" "0" "")
expect_empty "T2 Bash without gh pr create → noop" "$T2_JSON"

# ── T3: gh pr create + PR URL in stdout → systemMessage ─────────────────────
echo "=== T3: gh pr create + PR URL in stdout ==="
T3_URL="https://github.com/user/repo/pull/42"
T3_JSON=$(make_json "Bash" "gh pr create --title foo --body bar" "0" "$T3_URL")
T3_OUT=$(run_hook "$T3_JSON")
T3_MSG=$(extract_system_message "$T3_OUT")
if [ -z "$T3_MSG" ]; then
  fail "T3 expected systemMessage with PR info, got empty"
else
  if echo "$T3_MSG" | grep -qF "PR #42 created" && echo "$T3_MSG" | grep -qF "$T3_URL"; then
    pass "T3 systemMessage contains 'PR #42 created' and URL"
  else
    fail "T3 systemMessage missing PR# or URL — got: $T3_MSG"
  fi
  if echo "$T3_MSG" | grep -qF "Click Allow"; then
    pass "T3 systemMessage contains 'Click Allow'"
  else
    fail "T3 systemMessage missing 'Click Allow' — got: $T3_MSG"
  fi
fi

# ── T4: gh pr create + exit_code != 0 → empty stdout, exit 0 ────────────────
echo "=== T4: gh pr create + exit_code=1 ==="
T4_JSON=$(make_json "Bash" "gh pr create --title foo" "1" "")
expect_empty "T4 gh pr create with exit_code=1 → noop" "$T4_JSON"

# ── T5: gh pr create + no URL in stdout → empty stdout, exit 0 ──────────────
echo "=== T5: gh pr create + no URL in stdout ==="
T5_JSON=$(make_json "Bash" "gh pr create --title foo" "0" "some random output no url here")
expect_empty "T5 gh pr create without URL in stdout → noop" "$T5_JSON"

# ── T8: gh pr create + PR URL → openInBrowser IS called (marker written) ─────
# Positive-path test confirming pr-created-open.js actually invokes openInBrowser.
# This is the key regression test for agents#1706's premise: "pr-created-open.js
# is the sole/actual opener" — if this hook stopped calling openInBrowser the fix
# would silently suppress the browser open entirely (0 opens instead of 1).
echo "=== T8: gh pr create + PR URL → openInBrowser called (marker written) ==="
MARKER_T8="$ISOLATED_CFG_DIR/t8-marker.json"
T8_URL="https://github.com/user/repo/pull/42"
T8_JSON=$(make_json "Bash" "gh pr create --title foo" "0" "$T8_URL")
# Run with SHOW_USER_VERIFIED_NO_BROWSER unset so openInBrowser is actually invoked;
# SHOW_USER_VERIFIED_NO_SPAWN=1 is global (test-mode: writes marker instead of spawning).
(
  unset SHOW_USER_VERIFIED_NO_BROWSER
  SHOW_USER_VERIFIED_MARKER_FILE="$MARKER_T8" \
  run_hook "$T8_JSON" > /dev/null
)
if [ -f "$MARKER_T8" ] && node -e "
  const d = JSON.parse(require('fs').readFileSync('$MARKER_T8', 'utf8'));
  process.exit(d.args && d.args.includes('$T8_URL') ? 0 : 1);
" 2>/dev/null; then
  pass "T8 openInBrowser called — marker written with PR URL (pr-created-open.js is the sole opener)"
else
  fail "T8 — marker missing or wrong URL; pr-created-open.js did not invoke openInBrowser: $(cat "$MARKER_T8" 2>/dev/null || echo 'not found')"
fi

# ── T6: SHOW_USER_VERIFIED_NO_BROWSER=1 opt-out — marker NOT written ─────────
# Relocated from feature-show-user-verified.sh U15 (agents#1706): openInBrowser is
# now called only by pr-created-open.js, not show-user-verified-context.js.
# Tests hooks/lib/open-external.js line 15 (NO_BROWSER opt-out) via this hook.
echo "=== T6: SHOW_USER_VERIFIED_NO_BROWSER=1 → marker file NOT written ==="
MARKER_T6="$ISOLATED_CFG_DIR/t6-marker.json"
T6_URL="https://github.com/user/repo/pull/42"
T6_JSON=$(make_json "Bash" "gh pr create --title foo" "0" "$T6_URL")
# Run with NO_BROWSER=1 (NO_SPAWN=1 is already global — marker would be written
# if openInBrowser were called without the opt-out).
SHOW_USER_VERIFIED_NO_BROWSER=1 \
SHOW_USER_VERIFIED_MARKER_FILE="$MARKER_T6" \
run_hook "$T6_JSON" > /dev/null
if [ ! -f "$MARKER_T6" ]; then
  pass "T6 NO_BROWSER opt-out — marker file not written when SHOW_USER_VERIFIED_NO_BROWSER=1"
else
  fail "T6 — marker file written despite SHOW_USER_VERIFIED_NO_BROWSER=1: $(cat "$MARKER_T6")"
fi

# ── T7: non-http(s) URL rejection by openInBrowser ───────────────────────────
# Relocated from feature-show-user-verified.sh U16 (agents#1706): tests
# hooks/lib/open-external.js line 14 (URL scheme guard) directly, since
# pr-created-open.js's own URL regex would filter non-github URLs before
# reaching openInBrowser — testing via open-external.js require() directly.
echo "=== T7: non-http URL rejected by openInBrowser — marker NOT written ==="
MARKER_T7="$ISOLATED_CFG_DIR/t7-marker.json"
run_with_timeout node -e "
  process.env.SHOW_USER_VERIFIED_NO_SPAWN = '1';
  process.env.SHOW_USER_VERIFIED_MARKER_FILE = '$MARKER_T7';
  delete process.env.SHOW_USER_VERIFIED_NO_BROWSER;
  require('$AGENTS_DIR/hooks/lib/open-external').openInBrowser('javascript:alert(1)');
" 2>/dev/null
if [ ! -f "$MARKER_T7" ]; then
  pass "T7 non-http URL rejected — openInBrowser did not spawn for javascript: URL"
else
  fail "T7 — marker written for non-http URL; scheme guard did not fire: $(cat "$MARKER_T7")"
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

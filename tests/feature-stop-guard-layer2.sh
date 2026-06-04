#!/usr/bin/env bash
# Tests: hooks/stop-confirm-plan-guard.js
# Tags: stop-guard, hook, sentinel, layer2, workflow
# Tests for Layer 2 sentinel-miss detection in hooks/stop-confirm-plan-guard.js.
#
# Layer 2 (extension): after the existing path-emission scan, for each marker with
# suffix in {intent, outline, detail} where isConfirmOff(absPath) === false:
#   - Scan transcript backward to most recent user entry. If no Bash tool_use
#     contains <<WORKFLOW_CONFIRM_<SUFFIX>>>, emit a systemMessage (advisory).
#   - Symmetric USER_VERIFIED check: assistant text contains <<WORKFLOW_USER_VERIFIED:
#     but no Bash tool_use contains <<WORKFLOW_USER_VERIFIED → same reminder.
#
# Layer 2 outputs systemMessage (advisory) NOT decision:block. Tests assert exit 0.
#
# The Layer 2 extension to stop-confirm-plan-guard.js is implemented in a later
# step. When not yet present, tests SKIP gracefully (detected by absence of the
# Layer 2 marker string in the hook source).
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
HOOK="$AGENTS_DIR/hooks/stop-confirm-plan-guard.js"
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

# ── Skip gracefully if Layer 2 not yet implemented ─────────────────────────
if [[ ! -f "$HOOK" ]]; then
  echo "SKIP: hook not present ($HOOK)"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi
if ! grep -qF "Layer 2" "$HOOK" 2>/dev/null; then
  echo "SKIP: stop-confirm-plan-guard.js Layer 2 not yet implemented"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/sg2-plans-$$"
WORKFLOW_DIR_TEST="${NODE_TMPDIR}/sg2-workflow-$$"
TRANSCRIPT_DIR="${NODE_TMPDIR}/sg2-transcripts-$$"
mkdir -p "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$TRANSCRIPT_DIR"

ISOLATED_CFG_DIR="${NODE_TMPDIR}/sg2-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_TEST"

trap 'rm -rf "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$TRANSCRIPT_DIR" "$ISOLATED_CFG_DIR"' EXIT

unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

SID="sg2-test-$$"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Write a turn marker for the session.
write_marker() {
  local suffix="$1" absPath="$2"
  run_with_timeout node -e "
    const fs = require('fs');
    const path = require('path');
    const crypto = require('crypto');
    const dir = '$WORKFLOW_DIR_TEST';
    fs.mkdirSync(dir, { recursive: true });
    const rand = crypto.randomBytes(4).toString('hex');
    const file = path.join(dir, '$SID' + '.confirm-plan-turn-' + rand + '.json');
    fs.writeFileSync(file, JSON.stringify({
      absPath: '$absPath',
      suffix: '$suffix',
      ts: Date.now(),
      created_at: new Date().toISOString()
    }));
  " 2>/dev/null
}

# Build a transcript file with user + assistant entries.
# $1 = transcript path
# $2 = assistant text content (for the last assistant text)
# $3 = assistant Bash tool_use command (empty string = no tool_use)
build_transcript() {
  local tpath="$1" asst_text="$2" bash_cmd="$3"
  run_with_timeout node -e "
    const fs = require('fs');
    const tpath = process.argv[1];
    const asstText = process.argv[2];
    const bashCmd = process.argv[3];
    const lines = [];
    // user entry as scan boundary
    lines.push(JSON.stringify({ type: 'user', message: { role: 'user', content: 'go' } }));
    // assistant entry
    const content = [];
    if (asstText) content.push({ type: 'text', text: asstText });
    if (bashCmd) content.push({ type: 'tool_use', name: 'Bash', input: { command: bashCmd } });
    lines.push(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content } }));
    fs.writeFileSync(tpath, lines.join('\n') + '\n');
  " "$tpath" "$asst_text" "$bash_cmd"
}

clear_markers() {
  rm -f "$WORKFLOW_DIR_TEST/$SID".confirm-plan-turn-*.json 2>/dev/null || true
}

extract_system_message() {
  local result="$1"
  echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null
}

# Run hook with stdin JSON; returns exit code via global variable.
run_hook_with_rc() {
  local json="$1"
  HOOK_RC=0
  HOOK_OUT=$(echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null) || HOOK_RC=$?
}

# ── T1: marker(intent) + CONFIRM_INTENT=on + no sentinel → reminder ────────
echo "=== T1: marker(intent) + no sentinel → reminder systemMessage ==="
clear_markers
T1_PLAN="$PLANS_DIR/$SID-intent.md"
touch "$T1_PLAN"
write_marker "intent" "$T1_PLAN"
T1_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t1.jsonl"
build_transcript "$T1_TRANSCRIPT" "Plan written." ""
T1_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T1_TRANSCRIPT\"}"
run_hook_with_rc "$T1_JSON"
T1_MSG=$(extract_system_message "$HOOK_OUT")
if [ "$HOOK_RC" -ne 0 ]; then
  fail "T1 expected exit 0 (advisory), got exit $HOOK_RC"
elif echo "$T1_MSG" | grep -qF "[confirm-plan Layer 2]" && echo "$T1_MSG" | grep -qF "WORKFLOW_CONFIRM_INTENT"; then
  pass "T1 Layer 2 reminder emitted for missing WORKFLOW_CONFIRM_INTENT"
else
  fail "T1 expected Layer 2 reminder for INTENT, got: $HOOK_OUT"
fi
clear_markers

# ── T2: marker(intent) + WORKFLOW_CONFIRM_INTENT present → no reminder ─────
echo "=== T2: marker(intent) + sentinel emitted → no reminder ==="
clear_markers
T2_PLAN="$PLANS_DIR/$SID-intent.md"
touch "$T2_PLAN"
write_marker "intent" "$T2_PLAN"
T2_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t2.jsonl"
build_transcript "$T2_TRANSCRIPT" "Plan written." 'echo "<<WORKFLOW_CONFIRM_INTENT>>"'
T2_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T2_TRANSCRIPT\"}"
run_hook_with_rc "$T2_JSON"
T2_MSG=$(extract_system_message "$HOOK_OUT")
if [ "$HOOK_RC" -ne 0 ]; then
  fail "T2 expected exit 0, got exit $HOOK_RC"
elif echo "$T2_MSG" | grep -qF "[confirm-plan Layer 2]"; then
  fail "T2 unexpected Layer 2 reminder when sentinel present: $T2_MSG"
else
  pass "T2 no Layer 2 reminder when sentinel present"
fi
clear_markers

# ── T3: marker(intent) + CONFIRM_INTENT=off → no reminder (skip) ───────────
echo "=== T3: marker(intent) + CONFIRM_INTENT=off → no reminder ==="
clear_markers
T3_PLAN="$PLANS_DIR/$SID-intent.md"
touch "$T3_PLAN"
write_marker "intent" "$T3_PLAN"
T3_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t3.jsonl"
build_transcript "$T3_TRANSCRIPT" "Plan written." ""
T3_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T3_TRANSCRIPT\"}"
T3_OUT=$(
  export CONFIRM_INTENT=off
  echo "$T3_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T3_RC=$?
T3_MSG=$(extract_system_message "$T3_OUT")
if [ "$T3_RC" -ne 0 ]; then
  fail "T3 expected exit 0, got exit $T3_RC"
elif echo "$T3_MSG" | grep -qF "[confirm-plan Layer 2]"; then
  fail "T3 unexpected Layer 2 reminder when CONFIRM_INTENT=off: $T3_MSG"
else
  pass "T3 no Layer 2 reminder when CONFIRM_INTENT=off"
fi
clear_markers

# ── T4: no marker → no reminder (Layer 2 inactive) ─────────────────────────
echo "=== T4: no marker → no reminder ==="
clear_markers
T4_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t4.jsonl"
build_transcript "$T4_TRANSCRIPT" "Some text." ""
T4_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T4_TRANSCRIPT\"}"
run_hook_with_rc "$T4_JSON"
T4_MSG=$(extract_system_message "$HOOK_OUT")
if [ "$HOOK_RC" -ne 0 ]; then
  fail "T4 expected exit 0, got exit $HOOK_RC"
elif [ -z "$T4_MSG" ] || ! echo "$T4_MSG" | grep -qF "[confirm-plan Layer 2]"; then
  pass "T4 no Layer 2 reminder without marker"
else
  fail "T4 unexpected reminder without marker: $T4_MSG"
fi

# ── T5: USER_VERIFIED text-only sentinel → reminder systemMessage ──────────
echo "=== T5: USER_VERIFIED in assistant text only → reminder ==="
clear_markers
T5_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t5.jsonl"
build_transcript "$T5_TRANSCRIPT" "<<WORKFLOW_USER_VERIFIED: approved>>" ""
T5_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T5_TRANSCRIPT\"}"
run_hook_with_rc "$T5_JSON"
T5_MSG=$(extract_system_message "$HOOK_OUT")
if [ "$HOOK_RC" -ne 0 ]; then
  fail "T5 expected exit 0, got exit $HOOK_RC"
elif echo "$T5_MSG" | grep -qF "[confirm-plan Layer 2]" && echo "$T5_MSG" | grep -qF "WORKFLOW_USER_VERIFIED"; then
  pass "T5 USER_VERIFIED text-only → Layer 2 reminder emitted"
else
  fail "T5 expected USER_VERIFIED reminder, got: $HOOK_OUT"
fi

# ── T6: USER_VERIFIED in Bash tool_use → no reminder ───────────────────────
echo "=== T6: USER_VERIFIED in Bash tool_use → no reminder ==="
clear_markers
T6_TRANSCRIPT="$TRANSCRIPT_DIR/$SID-t6.jsonl"
build_transcript "$T6_TRANSCRIPT" "User verified." 'echo "<<WORKFLOW_USER_VERIFIED: approved>>"'
T6_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$T6_TRANSCRIPT\"}"
run_hook_with_rc "$T6_JSON"
T6_MSG=$(extract_system_message "$HOOK_OUT")
if [ "$HOOK_RC" -ne 0 ]; then
  fail "T6 expected exit 0, got exit $HOOK_RC"
elif echo "$T6_MSG" | grep -qF "[confirm-plan Layer 2]" && echo "$T6_MSG" | grep -qF "WORKFLOW_USER_VERIFIED"; then
  fail "T6 unexpected USER_VERIFIED reminder when in Bash tool_use: $T6_MSG"
else
  pass "T6 USER_VERIFIED in Bash tool_use → no reminder"
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

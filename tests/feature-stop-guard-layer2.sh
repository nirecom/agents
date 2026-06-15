#!/usr/bin/env bash
# Tests: hooks/stop-confirm-plan-guard.js
# Tags: stop-guard, hook, sentinel, layer2, workflow, confirm
# Tests for Layer 2 sentinel-followup detection in hooks/stop-confirm-plan-guard.js.
#
# Layer 2 (new contract for #842): for each CONFIRM_<STAGE> sentinel echoed in the
# LATEST assistant turn, scan the same turn for a stage-valid follow-up tool_use:
#   - CONFIRM_INTENT  -> Skill(make-outline-plan)
#   - CONFIRM_OUTLINE -> Skill(make-detail-plan)
#   - CONFIRM_DETAIL  -> Skill(write-tests) OR Bash(WORKFLOW_BRANCHING_COMPLETE)
# If the follow-up is missing, Layer 2 emits `decision:block + exit 2` with a
# reason derived from CONFIRM_NEXT_STEP_HINT (workflow-state.js). Layer 1
# (path-emission scan) is preserved unchanged.
#
# The Layer 2 extension is implemented in a later step. When not yet present,
# tests SKIP gracefully (detected by absence of "Layer 2" marker in the hook).
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

# Write a turn marker for the session (Layer 2 only activates when a marker exists).
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

clear_markers() {
  rm -f "$WORKFLOW_DIR_TEST/$SID".confirm-plan-turn-*.json 2>/dev/null || true
}

# Build a transcript file with one user entry + one assistant entry whose
# content array is supplied as a JSON string.
# $1 = transcript path
# $2 = JSON array string of content items
build_transcript_full() {
  local tpath="$1" content_json="$2"
  run_with_timeout node -e "
    const fs = require('fs');
    const tpath = process.argv[1];
    const contentJson = process.argv[2];
    const content = JSON.parse(contentJson);
    const lines = [];
    lines.push(JSON.stringify({ type: 'user', message: { role: 'user', content: 'go' } }));
    lines.push(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content } }));
    fs.writeFileSync(tpath, lines.join('\n') + '\n');
  " "$tpath" "$content_json"
}

# Build a transcript with two assistant turns: an older one and a newer one.
# Layer 2 must only scan the LATEST assistant turn.
# $1 = transcript path
# $2 = JSON array of content items for the OLDER assistant turn
# $3 = JSON array of content items for the LATEST assistant turn
build_transcript_two_turns() {
  local tpath="$1" old_json="$2" new_json="$3"
  run_with_timeout node -e "
    const fs = require('fs');
    const tpath = process.argv[1];
    const oldContent = JSON.parse(process.argv[2]);
    const newContent = JSON.parse(process.argv[3]);
    const lines = [];
    lines.push(JSON.stringify({ type: 'user', message: { role: 'user', content: 'go' } }));
    lines.push(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: oldContent } }));
    lines.push(JSON.stringify({ type: 'user', message: { role: 'user', content: 'next' } }));
    lines.push(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: newContent } }));
    fs.writeFileSync(tpath, lines.join('\n') + '\n');
  " "$tpath" "$old_json" "$new_json"
}

extract_decision() {
  local result="$1"
  echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.decision || '');
  " 2>/dev/null
}

extract_reason() {
  local result="$1"
  echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.reason || '');
  " 2>/dev/null
}

# Run hook with stdin JSON; captures both exit code and stdout.
run_hook_with_rc() {
  local json="$1"
  HOOK_RC=0
  HOOK_OUT=$(echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null) || HOOK_RC=$?
}

setup_marker() {
  local suffix="$1"
  local plan_path="$PLANS_DIR/$SID-${suffix}.md"
  touch "$plan_path"
  write_marker "$suffix" "$plan_path"
}

# Bash CONFIRM tool_use as JSON fragments — note the inner quotes match the
# CONFIRM_<STAGE>_RE_DQ regex (double-quoted echo with mandatory reason).
BASH_CONFIRM_INTENT='{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: scope clarified>>\""}}'
BASH_CONFIRM_OUTLINE='{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_CONFIRM_OUTLINE: approach A>>\""}}'
BASH_CONFIRM_DETAIL='{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_CONFIRM_DETAIL: file-level plan>>\""}}'
BASH_BRANCHING_COMPLETE='{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_BRANCHING_COMPLETE: worktree: /tmp/wt>>\""}}'

SKILL_OUTLINE='{"type":"tool_use","name":"Skill","input":{"skill":"make-outline-plan"}}'
SKILL_DETAIL='{"type":"tool_use","name":"Skill","input":{"skill":"make-detail-plan"}}'
SKILL_WRITE_TESTS='{"type":"tool_use","name":"Skill","input":{"skill":"write-tests"}}'
SKILL_CLARIFY_INTENT='{"type":"tool_use","name":"Skill","input":{"skill":"clarify-intent"}}'

TEXT_BLOCK='{"type":"text","text":"Some narration."}'

# ── L2a: CONFIRM_INTENT + Skill(make-outline-plan) after → exit 0 ─────────
echo "=== L2a: CONFIRM_INTENT + Skill(make-outline-plan) follow-up → pass ==="
clear_markers
setup_marker "intent"
L2A_TPATH="$TRANSCRIPT_DIR/$SID-l2a.jsonl"
build_transcript_full "$L2A_TPATH" "[$BASH_CONFIRM_INTENT,$SKILL_OUTLINE]"
L2A_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2A_TPATH\"}"
run_hook_with_rc "$L2A_JSON"
if [ "$HOOK_RC" -eq 0 ]; then
  pass "L2a stage-valid follow-up after CONFIRM_INTENT → exit 0"
else
  fail "L2a expected exit 0 (follow-up present), got exit $HOOK_RC, out: $HOOK_OUT"
fi
clear_markers

# ── L2b: CONFIRM_INTENT preceded by Skill (no follow-up after) → block ─────
echo "=== L2b: CONFIRM_INTENT with Skill BEFORE only → block ==="
clear_markers
setup_marker "intent"
L2B_TPATH="$TRANSCRIPT_DIR/$SID-l2b.jsonl"
build_transcript_full "$L2B_TPATH" "[$SKILL_CLARIFY_INTENT,$BASH_CONFIRM_INTENT]"
L2B_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2B_TPATH\"}"
run_hook_with_rc "$L2B_JSON"
L2B_DECISION=$(extract_decision "$HOOK_OUT")
L2B_REASON=$(extract_reason "$HOOK_OUT")
if [ "$HOOK_RC" -ne 2 ]; then
  fail "L2b expected exit 2, got exit $HOOK_RC, out: $HOOK_OUT"
elif [ "$L2B_DECISION" != "block" ]; then
  fail "L2b expected decision:block, got: '$L2B_DECISION' out: $HOOK_OUT"
elif ! echo "$L2B_REASON" | grep -qF "make-outline-plan"; then
  fail "L2b reason missing 'make-outline-plan': $L2B_REASON"
else
  pass "L2b CONFIRM_INTENT without follow-up Skill → block + intent hint"
fi
clear_markers

# ── L2c: CONFIRM_DETAIL + Bash(WORKFLOW_BRANCHING_COMPLETE) after → pass ───
echo "=== L2c: CONFIRM_DETAIL + WORKFLOW_BRANCHING_COMPLETE after → pass ==="
clear_markers
setup_marker "detail"
L2C_TPATH="$TRANSCRIPT_DIR/$SID-l2c.jsonl"
build_transcript_full "$L2C_TPATH" "[$BASH_CONFIRM_DETAIL,$BASH_BRANCHING_COMPLETE]"
L2C_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2C_TPATH\"}"
run_hook_with_rc "$L2C_JSON"
if [ "$HOOK_RC" -eq 0 ]; then
  pass "L2c CONFIRM_DETAIL + branching-complete follow-up → exit 0"
else
  fail "L2c expected exit 0, got exit $HOOK_RC, out: $HOOK_OUT"
fi
clear_markers

# ── L2d: branching-complete BEFORE CONFIRM_DETAIL (nothing after) → block ──
echo "=== L2d: branching-complete BEFORE CONFIRM_DETAIL only → block ==="
clear_markers
setup_marker "detail"
L2D_TPATH="$TRANSCRIPT_DIR/$SID-l2d.jsonl"
build_transcript_full "$L2D_TPATH" "[$BASH_BRANCHING_COMPLETE,$BASH_CONFIRM_DETAIL]"
L2D_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2D_TPATH\"}"
run_hook_with_rc "$L2D_JSON"
L2D_DECISION=$(extract_decision "$HOOK_OUT")
if [ "$HOOK_RC" -ne 2 ]; then
  fail "L2d expected exit 2, got exit $HOOK_RC, out: $HOOK_OUT"
elif [ "$L2D_DECISION" != "block" ]; then
  fail "L2d expected decision:block, got: '$L2D_DECISION' out: $HOOK_OUT"
else
  pass "L2d follow-up must come AFTER CONFIRM_DETAIL → block"
fi
clear_markers

# ── L2e: CONFIRM_OUTLINE alone (no follow-up at all) → block ───────────────
echo "=== L2e: CONFIRM_OUTLINE alone, no follow-up → block ==="
clear_markers
setup_marker "outline"
L2E_TPATH="$TRANSCRIPT_DIR/$SID-l2e.jsonl"
build_transcript_full "$L2E_TPATH" "[$BASH_CONFIRM_OUTLINE]"
L2E_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2E_TPATH\"}"
run_hook_with_rc "$L2E_JSON"
L2E_DECISION=$(extract_decision "$HOOK_OUT")
L2E_REASON=$(extract_reason "$HOOK_OUT")
if [ "$HOOK_RC" -ne 2 ]; then
  fail "L2e expected exit 2, got exit $HOOK_RC, out: $HOOK_OUT"
elif [ "$L2E_DECISION" != "block" ]; then
  fail "L2e expected decision:block, got: '$L2E_DECISION' out: $HOOK_OUT"
elif ! echo "$L2E_REASON" | grep -qF "make-detail-plan"; then
  fail "L2e reason missing 'make-detail-plan': $L2E_REASON"
else
  pass "L2e CONFIRM_OUTLINE alone → block + outline hint"
fi
clear_markers

# ── L2f: no CONFIRM sentinel at all → exit 0 (Layer 2 not triggered) ───────
echo "=== L2f: no CONFIRM sentinel → Layer 2 not triggered ==="
clear_markers
setup_marker "intent"
L2F_TPATH="$TRANSCRIPT_DIR/$SID-l2f.jsonl"
# Plain text + Skill + a non-CONFIRM Bash echo.
BASH_REGULAR='{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}'
build_transcript_full "$L2F_TPATH" "[$TEXT_BLOCK,$BASH_REGULAR,$SKILL_OUTLINE]"
L2F_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2F_TPATH\"}"
run_hook_with_rc "$L2F_JSON"
if [ "$HOOK_RC" -eq 0 ]; then
  pass "L2f no CONFIRM sentinel → exit 0 (Layer 2 inert)"
else
  fail "L2f expected exit 0, got exit $HOOK_RC, out: $HOOK_OUT"
fi
clear_markers

# ── L2g: CONFIRM in PAST turn only; latest turn has none → exit 0 ──────────
echo "=== L2g: CONFIRM in past turn; latest turn clean → no re-block ==="
clear_markers
setup_marker "intent"
L2G_TPATH="$TRANSCRIPT_DIR/$SID-l2g.jsonl"
# Older turn had CONFIRM_INTENT with NO follow-up (would have blocked then);
# latest turn is benign. Layer 2 must scan only the latest turn.
build_transcript_two_turns "$L2G_TPATH" \
  "[$BASH_CONFIRM_INTENT]" \
  "[$TEXT_BLOCK]"
L2G_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L2G_TPATH\"}"
run_hook_with_rc "$L2G_JSON"
if [ "$HOOK_RC" -eq 0 ]; then
  pass "L2g re-block prevention: only latest assistant turn scanned"
else
  fail "L2g expected exit 0 (latest turn clean), got exit $HOOK_RC, out: $HOOK_OUT"
fi
clear_markers

# ── Layer 1 regression: marker + assistant text contains WORKFLOW_PLANS_DIR ──
echo "=== L1-reg: Layer 1 path-emission scan still works ==="
clear_markers
setup_marker "intent"
L1R_TPATH="$TRANSCRIPT_DIR/$SID-l1r.jsonl"
# Embed the plans dir path inside an assistant text block.
PLANS_DIR_FWD="${PLANS_DIR//\\//}"
L1R_TEXT_JSON="$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({type:'text',text:'See plan at ' + process.argv[1] + '/intent.md'}));
" "$PLANS_DIR_FWD")"
build_transcript_full "$L1R_TPATH" "[$L1R_TEXT_JSON]"
L1R_JSON="{\"session_id\":\"$SID\",\"transcript_path\":\"$L1R_TPATH\"}"
run_hook_with_rc "$L1R_JSON"
L1R_DECISION=$(extract_decision "$HOOK_OUT")
if [ "$HOOK_RC" -ne 2 ]; then
  fail "L1-reg expected exit 2, got exit $HOOK_RC, out: $HOOK_OUT"
elif [ "$L1R_DECISION" != "block" ]; then
  fail "L1-reg expected decision:block, got: '$L1R_DECISION' out: $HOOK_OUT"
else
  pass "L1-reg Layer 1 path-emission block intact"
fi
clear_markers

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

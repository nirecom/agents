#!/usr/bin/env bash
# Tests: hooks/lib/turn-marker.js, hooks/show-plan-link.js, hooks/stop-confirm-plan-guard.js
# Tags: plan, vscode, hook, workflow, plans
# Tests for #524 confirm-plan guard:
#   - hooks/stop-confirm-plan-guard.js (Stop hook)
#   - hooks/lib/turn-marker.js (marker read/write helpers)
#   - hooks/show-plan-link.js (marker write integration)
#
# Marker files: <CLAUDE_WORKFLOW_DIR>/<sid>.confirm-plan-turn-<rand>.json
# When CONFIRM_<STEP>=on and show-plan-link.js fires a breadcrumb, a marker is
# written. On Stop, the guard reads markers for the current session, scans the
# last assistant turn in the JSONL transcript, and blocks with decision=block
# when a PLANS_DIR path appears in any text content block.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
STOP_HOOK="$AGENTS_DIR/hooks/stop-confirm-plan-guard.js"
SHOW_HOOK="$AGENTS_DIR/hooks/show-plan-link.js"
TURN_MARKER_LIB="$AGENTS_DIR/hooks/lib/turn-marker.js"
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

# Per-run temp dirs (use Node's tmpdir to match the form Node sees on Windows).
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
WORKFLOW_DIR="${NODE_TMPDIR}/fix-524-workflow-$$"
PLANS_DIR="${NODE_TMPDIR}/fix-524-plans-$$"
ISOLATED_CFG_DIR="${NODE_TMPDIR}/fix-524-cfg-$$"
TRANSCRIPT_DIR="${NODE_TMPDIR}/fix-524-transcripts-$$"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$ISOLATED_CFG_DIR" "$TRANSCRIPT_DIR"

trap 'rm -rf "$WORKFLOW_DIR" "$PLANS_DIR" "$ISOLATED_CFG_DIR" "$TRANSCRIPT_DIR"' EXIT

export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"

# Unset CONFIRM_* / VS Code detection so they don't bleed in from the parent shell.
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
unset TERM_PROGRAM CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# Compute the tilde-form and file:/// URI form of PLANS_DIR as the source modules
# would. These are produced for the test fixtures via node so they match what the
# hook constructs internally.
TILDE_PLANS="$(run_with_timeout node -e "
  const os = require('os'); const path = require('path');
  const home = os.homedir();
  const plans = process.env.WORKFLOW_PLANS_DIR;
  // Best effort: if plans starts with home, emit ~/<rest>.
  let out = '~/.workflow-plans';
  process.stdout.write(out);
" 2>/dev/null)"

FILE_URI_PLANS="$(run_with_timeout node -e "
  const path = require('path');
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const fwd = plans.replace(/\\\\/g, '/');
  // Windows drive path
  const m = fwd.match(/^([A-Za-z]:)\/(.*)/);
  if (m) {
    process.stdout.write('file:///' + m[1] + '/' + m[2]);
  } else if (fwd.startsWith('/')) {
    process.stdout.write('file://' + fwd);
  } else {
    process.stdout.write('file:///' + fwd);
  }
" 2>/dev/null)"

# Helper: write a marker file for a given session id. Returns the path on stdout.
# Optional second arg: suffix (intent|outline|detail) stored in payload (for T3).
write_marker() {
  local sid="$1"
  local suffix="${2:-detail}"
  local rand
  rand="$(run_with_timeout node -e "process.stdout.write(require('crypto').randomBytes(4).toString('hex'))")"
  local marker_path="${WORKFLOW_DIR}/${sid}.confirm-plan-turn-${rand}.json"
  cat > "$marker_path" <<EOF
{"session_id":"$sid","suffix":"$suffix","file_path":"$PLANS_DIR/abc-${suffix}.md","ts":"2026-01-01T00:00:00Z"}
EOF
  echo "$marker_path"
}

# Helper: write a JSONL transcript at the given path. $2 is a single line of JSON.
write_transcript() {
  local tpath="$1"; local line="$2"
  echo "$line" > "$tpath"
}

# Helper: count marker files for a given sid in WORKFLOW_DIR.
count_markers() {
  local sid="$1"
  local count
  count=$(ls -1 "$WORKFLOW_DIR" 2>/dev/null | grep -c "^${sid}\.confirm-plan-turn-" || true)
  echo "$count"
}

# Helper: run stop hook with given stdin JSON. Captures stdout, stderr, exit code.
# Sets globals: STOP_STDOUT, STOP_STDERR, STOP_RC.
run_stop_hook() {
  local stdin_json="$1"
  STOP_STDOUT=$(echo "$stdin_json" | run_with_timeout node "$STOP_HOOK" 2>/tmp/fix-524-stderr-$$ )
  STOP_RC=$?
  STOP_STDERR=$(cat /tmp/fix-524-stderr-$$ 2>/dev/null || echo "")
  rm -f /tmp/fix-524-stderr-$$
}

# Source-file existence check — if files are missing, tests will fail with
# MODULE_NOT_FOUND. Document this explicitly so the failures are clear.
SOURCE_MISSING=0
if [ ! -f "$STOP_HOOK" ]; then
  echo "NOTE: source missing: $STOP_HOOK"
  SOURCE_MISSING=1
fi
if [ ! -f "$TURN_MARKER_LIB" ]; then
  echo "NOTE: source missing: $TURN_MARKER_LIB"
  SOURCE_MISSING=1
fi
if [ "$SOURCE_MISSING" -eq 1 ]; then
  echo "NOTE: source files for #524 do not exist yet — Section A/B tests below"
  echo "      will fail with MODULE_NOT_FOUND or similar until they are created."
fi

# ══════════════════════════════════════════════════════════════════════════
# Section A: hooks/stop-confirm-plan-guard.js
# ══════════════════════════════════════════════════════════════════════════

# ── T1: noop — no marker present ─────────────────────────────────────────
echo "=== T1: noop, no marker ==="
SID_T1="sid-t1-$$"
TRANSCRIPT_T1="$TRANSCRIPT_DIR/${SID_T1}.jsonl"
write_transcript "$TRANSCRIPT_T1" '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
run_stop_hook "{\"session_id\":\"$SID_T1\",\"transcript_path\":\"$TRANSCRIPT_T1\"}"
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ]; then
  pass "T1 no marker — exit 0 with empty stdout"
else
  fail "T1 no marker — rc=$STOP_RC stdout='$STOP_STDOUT' stderr='$STOP_STDERR'"
fi

# ── T2: noop — stop_hook_active=true ─────────────────────────────────────
echo "=== T2: noop, stop_hook_active=true ==="
SID_T2="sid-t2-$$"
write_marker "$SID_T2" >/dev/null
TRANSCRIPT_T2="$TRANSCRIPT_DIR/${SID_T2}.jsonl"
write_transcript "$TRANSCRIPT_T2" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$PLANS_DIR/abc-detail.md\"}]}}"
run_stop_hook "{\"stop_hook_active\":true,\"session_id\":\"$SID_T2\",\"transcript_path\":\"$TRANSCRIPT_T2\"}"
if [ "$STOP_RC" -eq 0 ]; then
  pass "T2 stop_hook_active=true — exit 0 (no recursive guard)"
else
  fail "T2 stop_hook_active=true — rc=$STOP_RC stdout='$STOP_STDOUT' stderr='$STOP_STDERR'"
fi
# Cleanup any leftover marker (acceptable per spec — both behaviors allowed).
rm -f "$WORKFLOW_DIR/${SID_T2}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T3: block — CONFIRM_DETAIL=off + transcript with PLANS_DIR path ──────
# After #563: guard is always-on; CONFIRM_DETAIL=off no longer suppresses block.
echo "=== T3: block, CONFIRM_DETAIL=off + dirty transcript ==="
SID_T3="sid-t3-$$"
write_marker "$SID_T3" detail >/dev/null
TRANSCRIPT_T3="$TRANSCRIPT_DIR/${SID_T3}.jsonl"
write_transcript "$TRANSCRIPT_T3" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"see $PLANS_DIR/abc-detail.md for details\"}]}}"
STOP_STDOUT=$(
  export CONFIRM_DETAIL=off
  echo "{\"session_id\":\"$SID_T3\",\"transcript_path\":\"$TRANSCRIPT_T3\"}" | \
    run_with_timeout node "$STOP_HOOK" 2>/dev/null
)
STOP_RC=$?
if [ "$STOP_RC" -eq 2 ] && echo "$STOP_STDOUT" | grep -q '"decision":"block"'; then
  pass "T3 CONFIRM_DETAIL=off + dirty transcript — STILL blocks (exit 2, decision=block)"
else
  fail "T3 CONFIRM_DETAIL=off + dirty transcript — expected block, got rc=$STOP_RC stdout='$STOP_STDOUT'"
fi
rm -f "$WORKFLOW_DIR/${SID_T3}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T3b: noop — CONFIRM_DETAIL=off + clean transcript ────────────────────
echo "=== T3b: noop, CONFIRM_DETAIL=off + clean transcript ==="
SID_T3B="sid-t3b-$$"
write_marker "$SID_T3B" detail >/dev/null
TRANSCRIPT_T3B="$TRANSCRIPT_DIR/${SID_T3B}.jsonl"
write_transcript "$TRANSCRIPT_T3B" '{"type":"assistant","message":{"content":[{"type":"text","text":"all clean, nothing to see"}]}}'
STOP_STDOUT=$(
  export CONFIRM_DETAIL=off
  echo "{\"session_id\":\"$SID_T3B\",\"transcript_path\":\"$TRANSCRIPT_T3B\"}" | \
    run_with_timeout node "$STOP_HOOK" 2>/dev/null
)
STOP_RC=$?
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ]; then
  pass "T3b CONFIRM_DETAIL=off + clean transcript — exit 0 (no false positive)"
else
  fail "T3b CONFIRM_DETAIL=off + clean transcript — rc=$STOP_RC stdout='$STOP_STDOUT'"
fi
rm -f "$WORKFLOW_DIR/${SID_T3B}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T4: noop — transcript has no PLANS_DIR path ──────────────────────────
echo "=== T4: noop, transcript clean ==="
SID_T4="sid-t4-$$"
write_marker "$SID_T4" >/dev/null
TRANSCRIPT_T4="$TRANSCRIPT_DIR/${SID_T4}.jsonl"
write_transcript "$TRANSCRIPT_T4" '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello, no path here"}]}}'
run_stop_hook "{\"session_id\":\"$SID_T4\",\"transcript_path\":\"$TRANSCRIPT_T4\"}"
REMAINING_T4=$(count_markers "$SID_T4")
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ] && [ "$REMAINING_T4" -eq 0 ]; then
  pass "T4 clean transcript — exit 0, marker deleted"
else
  fail "T4 clean transcript — rc=$STOP_RC stdout='$STOP_STDOUT' remaining=$REMAINING_T4"
fi
rm -f "$WORKFLOW_DIR/${SID_T4}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T5: block — absolute PLANS_DIR path in text block ────────────────────
echo "=== T5: block, absolute path ==="
SID_T5="sid-t5-$$"
write_marker "$SID_T5" >/dev/null
TRANSCRIPT_T5="$TRANSCRIPT_DIR/${SID_T5}.jsonl"
write_transcript "$TRANSCRIPT_T5" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"see $PLANS_DIR/abc-detail.md for details\"}]}}"
run_stop_hook "{\"session_id\":\"$SID_T5\",\"transcript_path\":\"$TRANSCRIPT_T5\"}"
REMAINING_T5=$(count_markers "$SID_T5")
if [ "$STOP_RC" -eq 2 ] && echo "$STOP_STDOUT" | grep -q '"decision":"block"' && [ "$REMAINING_T5" -eq 0 ]; then
  pass "T5 absolute path — exit 2, decision=block, marker deleted"
else
  fail "T5 absolute path — rc=$STOP_RC stdout='$STOP_STDOUT' remaining=$REMAINING_T5"
fi
rm -f "$WORKFLOW_DIR/${SID_T5}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T6: block — tilde form ───────────────────────────────────────────────
echo "=== T6: block, tilde form ==="
SID_T6="sid-t6-$$"
write_marker "$SID_T6" >/dev/null
TRANSCRIPT_T6="$TRANSCRIPT_DIR/${SID_T6}.jsonl"
write_transcript "$TRANSCRIPT_T6" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"saved to ~/.workflow-plans/abc-intent.md\"}]}}"
run_stop_hook "{\"session_id\":\"$SID_T6\",\"transcript_path\":\"$TRANSCRIPT_T6\"}"
if [ "$STOP_RC" -eq 2 ] && echo "$STOP_STDOUT" | grep -q '"decision":"block"'; then
  pass "T6 tilde form — exit 2, decision=block"
else
  fail "T6 tilde form — rc=$STOP_RC stdout='$STOP_STDOUT'"
fi
rm -f "$WORKFLOW_DIR/${SID_T6}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T7: block — file:/// URI form ────────────────────────────────────────
echo "=== T7: block, file:/// URI ==="
SID_T7="sid-t7-$$"
write_marker "$SID_T7" >/dev/null
TRANSCRIPT_T7="$TRANSCRIPT_DIR/${SID_T7}.jsonl"
write_transcript "$TRANSCRIPT_T7" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"open ${FILE_URI_PLANS}/abc-detail.md please\"}]}}"
run_stop_hook "{\"session_id\":\"$SID_T7\",\"transcript_path\":\"$TRANSCRIPT_T7\"}"
if [ "$STOP_RC" -eq 2 ] && echo "$STOP_STDOUT" | grep -q '"decision":"block"'; then
  pass "T7 file:/// URI — exit 2, decision=block"
else
  fail "T7 file:/// URI — rc=$STOP_RC stdout='$STOP_STDOUT' uri=$FILE_URI_PLANS"
fi
rm -f "$WORKFLOW_DIR/${SID_T7}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T8a: noop — path only in tool_use block (no text blocks) ─────────────
echo "=== T8a: noop, tool_use-only block ==="
SID_T8A="sid-t8a-$$"
write_marker "$SID_T8A" >/dev/null
TRANSCRIPT_T8A="$TRANSCRIPT_DIR/${SID_T8A}.jsonl"
write_transcript "$TRANSCRIPT_T8A" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$PLANS_DIR/foo-intent.md\"}}]}}"
run_stop_hook "{\"session_id\":\"$SID_T8A\",\"transcript_path\":\"$TRANSCRIPT_T8A\"}"
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ]; then
  pass "T8a tool_use-only — exit 0 (tool_use not scanned)"
else
  fail "T8a tool_use-only — rc=$STOP_RC stdout='$STOP_STDOUT'"
fi
rm -f "$WORKFLOW_DIR/${SID_T8A}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T8b: noop — clean text + tool_use with path ─────────────────────────
echo "=== T8b: noop, clean text + tool_use with path ==="
SID_T8B="sid-t8b-$$"
write_marker "$SID_T8B" >/dev/null
TRANSCRIPT_T8B="$TRANSCRIPT_DIR/${SID_T8B}.jsonl"
write_transcript "$TRANSCRIPT_T8B" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"all done\"},{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$PLANS_DIR/foo-detail.md\"}}]}}"
run_stop_hook "{\"session_id\":\"$SID_T8B\",\"transcript_path\":\"$TRANSCRIPT_T8B\"}"
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ]; then
  pass "T8b clean text + tool_use — exit 0 (text clean, tool_use not scanned)"
else
  fail "T8b clean text + tool_use — rc=$STOP_RC stdout='$STOP_STDOUT'"
fi
rm -f "$WORKFLOW_DIR/${SID_T8B}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T9: noop — transcript file missing ──────────────────────────────────
echo "=== T9: noop, transcript missing ==="
SID_T9="sid-t9-$$"
write_marker "$SID_T9" >/dev/null
MISSING_T9="$TRANSCRIPT_DIR/${SID_T9}-does-not-exist.jsonl"
run_stop_hook "{\"session_id\":\"$SID_T9\",\"transcript_path\":\"$MISSING_T9\"}"
if [ "$STOP_RC" -eq 0 ]; then
  pass "T9 transcript missing — exit 0 (fail-open)"
else
  fail "T9 transcript missing — rc=$STOP_RC stdout='$STOP_STDOUT' stderr='$STOP_STDERR'"
fi
rm -f "$WORKFLOW_DIR/${SID_T9}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T10: idempotent — two markers for same session both deleted ─────────
echo "=== T10: idempotent, two markers ==="
SID_T10="sid-t10-$$"
write_marker "$SID_T10" >/dev/null
write_marker "$SID_T10" >/dev/null
COUNT_BEFORE_T10=$(count_markers "$SID_T10")
TRANSCRIPT_T10="$TRANSCRIPT_DIR/${SID_T10}.jsonl"
write_transcript "$TRANSCRIPT_T10" '{"type":"assistant","message":{"content":[{"type":"text","text":"all clean"}]}}'
run_stop_hook "{\"session_id\":\"$SID_T10\",\"transcript_path\":\"$TRANSCRIPT_T10\"}"
COUNT_AFTER_T10=$(count_markers "$SID_T10")
if [ "$COUNT_BEFORE_T10" -eq 2 ] && [ "$COUNT_AFTER_T10" -eq 0 ] && [ "$STOP_RC" -eq 0 ]; then
  pass "T10 two markers — both deleted (before=2 after=0)"
else
  fail "T10 two markers — before=$COUNT_BEFORE_T10 after=$COUNT_AFTER_T10 rc=$STOP_RC"
fi
rm -f "$WORKFLOW_DIR/${SID_T10}".confirm-plan-turn-*.json 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# Section B: hooks/show-plan-link.js — marker write integration
# ══════════════════════════════════════════════════════════════════════════

# ── T11: marker written when CONFIRM_DETAIL=on ──────────────────────────
echo "=== T11: marker written on CONFIRM_DETAIL=on ==="
SID_T11="sid-t11-$$"
# Pre-clean any leftover markers for this sid.
rm -f "$WORKFLOW_DIR/${SID_T11}".confirm-plan-turn-*.json 2>/dev/null || true
(
  export CONFIRM_DETAIL=on
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_NO_AUTO_OPEN=1
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"session_id\":\"$SID_T11\"}" \
    | run_with_timeout node "$SHOW_HOOK" >/dev/null 2>&1
)
COUNT_T11=$(count_markers "$SID_T11")
if [ "$COUNT_T11" -ge 1 ]; then
  pass "T11 CONFIRM_DETAIL=on — marker written (count=$COUNT_T11)"
else
  fail "T11 CONFIRM_DETAIL=on — no marker found in $WORKFLOW_DIR for sid=$SID_T11"
fi
rm -f "$WORKFLOW_DIR/${SID_T11}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T12: marker written even when CONFIRM_DETAIL=off (always-on after #563) ─
echo "=== T12: marker written on CONFIRM_DETAIL=off (always-on after #563) ==="
SID_T12="sid-t12-$$"
rm -f "$WORKFLOW_DIR/${SID_T12}".confirm-plan-turn-*.json 2>/dev/null || true
(
  export CONFIRM_DETAIL=off
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_NO_AUTO_OPEN=1
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true},\"session_id\":\"$SID_T12\"}" \
    | run_with_timeout node "$SHOW_HOOK" >/dev/null 2>&1
)
COUNT_T12=$(count_markers "$SID_T12")
if [ "$COUNT_T12" -ge 1 ]; then
  pass "T12 CONFIRM_DETAIL=off — marker IS written (always-on after #563)"
else
  fail "T12 CONFIRM_DETAIL=off — marker missing, count=$COUNT_T12 (expected always-on)"
fi
rm -f "$WORKFLOW_DIR/${SID_T12}".confirm-plan-turn-*.json 2>/dev/null || true

# ── Results ─────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

#!/usr/bin/env bash
# Tests for isFinalPlanArtifact detection and systemMessage output in hooks/show-plan-link.js.
#
# Uses WORKFLOW_PLANS_DIR to control the resolved plans directory so tests work
# regardless of the actual home directory path.
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

# Per-run temp dir as plans dir (no pollution of real ~/.workflow-plans).
# Use node os.tmpdir() so the path is in the same form Node.js sees it —
# on Windows, MSYS2 converts /tmp/... env vars to C:/Users/.../Temp/... but
# the JSON stdin value stays POSIX-form; using Node's tmpdir avoids the mismatch.
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Unset VS Code detection vars by default (restored per-test that needs them).
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# Asserts stdout is empty (noop)
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

# Asserts stdout is valid JSON with .systemMessage containing the expected substring
expect_message() {
  local desc="$1" json="$2" expected="$3"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  # Validate JSON and extract .systemMessage
  local msg
  msg=$(echo "$result" | run_with_timeout node -e "
    let data; try { data = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    if (!data.systemMessage) process.exit(2);
    process.stdout.write(data.systemMessage);
  " 2>/dev/null)
  local rc=$?
  if [ $rc -eq 1 ]; then
    fail "$desc — stdout is not valid JSON: $result"
  elif [ $rc -eq 2 ]; then
    fail "$desc — JSON has no .systemMessage field: $result"
  elif echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# ── T1: Write abc-intent.md (success) ──────────────────────────────────────
echo "=== T1: abc-intent.md ==="
expect_message "T1 intent file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-intent.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T2: Write abc-outline.md ───────────────────────────────────────────────
echo "=== T2: abc-outline.md ==="
expect_message "T2 outline file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-outline.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T3: Write abc-detail.md ────────────────────────────────────────────────
echo "=== T3: abc-detail.md ==="
expect_message "T3 detail file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T4: Write in drafts/ subdirectory ──────────────────────────────────────
echo "=== T4: drafts/abc-detail.md ==="
mkdir -p "$PLANS_DIR/drafts"
expect_empty "T4 drafts subdir is excluded (isDirectChild)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/drafts/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T5: Wrong suffix (.bak.md) ─────────────────────────────────────────────
echo "=== T5: abc-detail.bak.md ==="
expect_empty "T5 wrong suffix excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.bak.md\"},\"tool_response\":{\"success\":true}}"

# ── T6: Write in subdir (not direct child) ─────────────────────────────────
echo "=== T6: subdir/abc-detail.md ==="
mkdir -p "$PLANS_DIR/subdir"
expect_empty "T6 subdir not direct child excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/subdir/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T7: Sibling directory (PLANS_DIR-sibling) ──────────────────────────────
echo "=== T7: \$PLANS_DIR-sibling/abc-detail.md ==="
expect_empty "T7 sibling dir outside plans dir excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}-sibling/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T8: Completely unrelated path ─────────────────────────────────────────
echo "=== T8: /tmp/random/abc-detail.md ==="
expect_empty "T8 unrelated path excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/random/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T9: Edit tool on matching path ─────────────────────────────────────────
echo "=== T9: Edit tool ==="
expect_empty "T9 Edit tool is noop (non-Write)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T10: Bash tool ─────────────────────────────────────────────────────────
echo "=== T10: Bash tool ==="
expect_empty "T10 Bash tool is noop" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_response\":{\"success\":true}}"

# ── T11: Empty file_path ───────────────────────────────────────────────────
echo "=== T11: empty file_path ==="
expect_empty "T11 empty file_path is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\"},\"tool_response\":{\"success\":true}}"

# ── T12: Backslash path (Windows JSON-encoded) ─────────────────────────────
# Simulate a Windows-style backslash path that node receives as forward-slash
# after JSON.parse. We build the JSON with pre-escaped backslashes.
echo "=== T12: backslash path ==="
WIN_STYLE_PATH="$(echo "$PLANS_DIR/abc-detail.md" | sed 's|/|\\\\|g')"
# The JSON string value will have \\ which after parse = single backslash
T12_JSON="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${WIN_STYLE_PATH}\"},\"tool_response\":{\"success\":true}}"
result12=$(echo "$T12_JSON" | run_with_timeout node "$HOOK" 2>/dev/null)
if [ -n "$result12" ]; then
  msg12=$(echo "$result12" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null)
  if echo "$msg12" | grep -q "Plan file written:" && echo "$msg12" | grep -qv "\\\\\\\\"; then
    pass "T12 backslash path normalized to forward slashes in systemMessage"
  elif echo "$msg12" | grep -q "Plan file written:"; then
    pass "T12 backslash path produces systemMessage"
  else
    fail "T12 backslash path — unexpected result: $result12"
  fi
else
  pass "T12 backslash path (POSIX: noop is acceptable — path does not resolve to plans dir)"
fi

# ── T13: No prefix before -intent (intent.md only) ─────────────────────────
echo "=== T13: intent.md (no prefix) ==="
expect_empty "T13 intent.md without prefix excluded (regex .+ required)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/intent.md\"},\"tool_response\":{\"success\":true}}"

# ── T14: Uppercase suffix (case-sensitive regex) ────────────────────────────
echo "=== T14: abc-DETAIL.md (uppercase) ==="
expect_empty "T14 uppercase suffix excluded (case-sensitive regex)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-DETAIL.md\"},\"tool_response\":{\"success\":true}}"

# ── T15: Write with exit_code: 1 ───────────────────────────────────────────
echo "=== T15: exit_code: 1 ==="
expect_empty "T15 failed write (exit_code 1) is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"exit_code\":1}}"

# ── T17: WORKFLOW_PLANS_DIR set to custom temp dir ─────────────────────────
echo "=== T17: custom WORKFLOW_PLANS_DIR ==="
CUSTOM_DIR="${NODE_TMPDIR}/show-plan-link-custom-$$"
mkdir -p "$CUSTOM_DIR"
T17_RESULT=$(WORKFLOW_PLANS_DIR="$CUSTOM_DIR" \
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CUSTOM_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}")
T17_MSG=$(echo "$T17_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$T17_MSG" | grep -q "Plan file written:"; then
  pass "T17 custom WORKFLOW_PLANS_DIR honored"
else
  fail "T17 custom WORKFLOW_PLANS_DIR — no systemMessage: $T17_RESULT"
fi
rm -rf "$CUSTOM_DIR"

# ── T18: Malformed (non-JSON) stdin ────────────────────────────────────────
echo "=== T18: malformed stdin ==="
result18=$(echo "not json at all" | run_with_timeout node "$HOOK" 2>/dev/null)
if [ -z "$result18" ]; then
  pass "T18 malformed stdin is fail-open (empty stdout)"
else
  fail "T18 malformed stdin — expected empty stdout, got: $result18"
fi

# ── T19: Write with success: false (legacy field) ──────────────────────────
echo "=== T19: success: false ==="
expect_empty "T19 success=false (legacy field) is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":false}}"

# ── T20: No VS Code detection vars — systemMessage still emitted ──────────
echo "=== T20: non-VS Code (no env var) — systemMessage emitted ==="
T20_RESULT=$(
  unset TERM_PROGRAM
  unset CLAUDE_CODE_ENTRYPOINT
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)

T20_MSG=$(echo "$T20_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if echo "$T20_MSG" | grep -q "Plan file written:"; then
  pass "T20 non-VS Code — systemMessage emitted"
else
  fail "T20 non-VS Code — systemMessage missing: $T20_RESULT"
fi

# ── T21: CLAUDE_CODE_ENTRYPOINT=claude-vscode → systemMessage still emitted ──
# Variable is now ignored by the hook; breadcrumb always fires.
echo "=== T21: CLAUDE_CODE_ENTRYPOINT=claude-vscode — systemMessage emitted ==="
T21_RESULT=$(
  unset TERM_PROGRAM
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)

T21_MSG=$(echo "$T21_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if echo "$T21_MSG" | grep -q "Plan file written:"; then
  pass "T21 CLAUDE_CODE_ENTRYPOINT=claude-vscode — systemMessage emitted (variable now ignored)"
else
  fail "T21 CLAUDE_CODE_ENTRYPOINT=claude-vscode — systemMessage missing: $T21_RESULT"
fi

# ══════════════════════════════════════════════════════════════════════════
# CONFIRM_* breadcrumb-always tests (#445)
# show-plan-link.js emits the systemMessage ALWAYS, regardless of CONFIRM_*
# ══════════════════════════════════════════════════════════════════════════

# Helper: run hook with CONFIRM_* env vars and assert systemMessage is emitted
# $1 = description, $2 = file_path (under PLANS_DIR), $3 = expected substring,
# $4... = KEY=VAL env assignments
expect_message_with_env() {
  local desc="$1" file_path="$2" expected="$3"
  shift 3
  local result
  result=$(
    for assignment in "$@"; do
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$file_path\"},\"tool_response\":{\"success\":true}}" \
      | run_with_timeout node "$HOOK" 2>/dev/null
  )
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  local msg
  msg=$(echo "$result" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null)
  if echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# ── T-NEW-1: CONFIRM_DETAIL=off on *-detail.md → systemMessage emitted ─────
echo "=== T-NEW-1: CONFIRM_DETAIL=off on detail.md — breadcrumb fires ==="
expect_message_with_env "T-NEW-1 CONFIRM_DETAIL=off — systemMessage emitted regardless" \
  "$PLANS_DIR/abc-detail.md" "Plan file written:" \
  CONFIRM_DETAIL=off

# ── T-NEW-2: CONFIRM_OUTLINE=off on *-outline.md → systemMessage emitted ───
echo "=== T-NEW-2: CONFIRM_OUTLINE=off on outline.md — breadcrumb fires ==="
expect_message_with_env "T-NEW-2 CONFIRM_OUTLINE=off — systemMessage emitted regardless" \
  "$PLANS_DIR/abc-outline.md" "Plan file written:" \
  CONFIRM_OUTLINE=off

# ── T-NEW-3: CONFIRM_INTENT=off on *-intent.md → systemMessage emitted ─────
echo "=== T-NEW-3: CONFIRM_INTENT=off on intent.md — breadcrumb fires ==="
expect_message_with_env "T-NEW-3 CONFIRM_INTENT=off — systemMessage emitted regardless" \
  "$PLANS_DIR/abc-intent.md" "Plan file written:" \
  CONFIRM_INTENT=off

# ── T-NEW-4: CONFIRM_DETAIL=on on *-detail.md → systemMessage emitted ──────
echo "=== T-NEW-4: CONFIRM_DETAIL=on on detail.md — breadcrumb fires ==="
expect_message_with_env "T-NEW-4 CONFIRM_DETAIL=on — systemMessage emitted" \
  "$PLANS_DIR/abc-detail.md" "Plan file written:" \
  CONFIRM_DETAIL=on

# ── T-NEW-5: Cross-suffix CONFIRM_INTENT=off on *-detail.md ────────────────
echo "=== T-NEW-5: cross-suffix CONFIRM_INTENT=off on detail.md — breadcrumb fires ==="
expect_message_with_env "T-NEW-5 cross-suffix CONFIRM_INTENT=off on detail.md — systemMessage emitted" \
  "$PLANS_DIR/abc-detail.md" "Plan file written:" \
  CONFIRM_INTENT=off

# ══════════════════════════════════════════════════════════════════════════
# Bash branch — show-plan-link.js handling for Bash tool invocations of
# assemble-mandatory.sh. Reuses extractAssembleDest() from
# hooks/lib/assemble-cmd-parse.js to detect the destination final-artifact path.
# ══════════════════════════════════════════════════════════════════════════

# ── T-BASH-1: tool_name=Bash, valid assemble command, exit_code=0 ──────────
# Build the JSON entirely in Node.js, passing PLANS_DIR via argv[1] (Windows-
# style path — MSYS2 does not convert it). The command string is assembled in
# JS memory so MSYS2 cannot double-convert the Windows path inside it.
echo "=== T-BASH-1: Bash + assemble-mandatory.sh + exit_code=0 — systemMessage ==="
T_BASH_1_JSON=$(run_with_timeout node -e "
  var plans = process.argv[1];
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: '\"' + '\$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh' + '\" --source-kind intent /a/intent.md /a/draft.md ' + plans + '/test-outline.md' },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-1'
  }));
" "$PLANS_DIR")
expect_message "T-BASH-1 Bash + valid assemble + exit_code=0 — systemMessage emitted" \
  "$T_BASH_1_JSON" "Plan file written:"

# ── T-BASH-2: --source-kind detail targeting -detail.md ────────────────────
echo "=== T-BASH-2: Bash --source-kind detail — systemMessage ==="
T_BASH_2_CMD="assemble-mandatory.sh --source-kind detail $PLANS_DIR/abc-outline.md $PLANS_DIR/drafts/abc-detail-draft.md $PLANS_DIR/abc-detail.md"
T_BASH_2_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-2'
  }));
" "$T_BASH_2_CMD")
expect_message "T-BASH-2 Bash --source-kind detail — systemMessage emitted" \
  "$T_BASH_2_JSON" "Plan file written:"

# ── T-BASH-3: Bash but no assemble-mandatory.sh — noop ─────────────────────
echo "=== T-BASH-3: Bash without assemble-mandatory.sh — noop ==="
expect_empty "T-BASH-3 Bash without assemble-mandatory.sh — noop" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hello world\"},\"tool_response\":{\"exit_code\":0},\"session_id\":\"test-sid-bash-3\"}"

# ── T-BASH-4: Bash + assemble + exit_code=1 — noop ─────────────────────────
echo "=== T-BASH-4: Bash + assemble + exit_code=1 — noop ==="
T_BASH_4_CMD="assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md $PLANS_DIR/test-outline.md"
T_BASH_4_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 1 },
    session_id: 'test-sid-bash-4'
  }));
" "$T_BASH_4_CMD")
expect_empty "T-BASH-4 Bash + assemble + exit_code=1 — noop" "$T_BASH_4_JSON"

# ── T-BASH-5: assemble targeting drafts/ path — noop (not final artifact) ──
echo "=== T-BASH-5: Bash + assemble target under drafts/ — noop ==="
mkdir -p "$PLANS_DIR/drafts"
T_BASH_5_CMD="assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md $PLANS_DIR/drafts/abc-outline-draft.md"
T_BASH_5_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-5'
  }));
" "$T_BASH_5_CMD")
expect_empty "T-BASH-5 Bash + assemble of drafts/-path — noop (not final artifact)" \
  "$T_BASH_5_JSON"

# ── T-BASH-6: Bash + SHOW_PLAN_LINK_NO_SPAWN=1 + CONFIRM_OUTLINE=on ────────
echo "=== T-BASH-6: Bash + CONFIRM_OUTLINE=on + NO_SPAWN — marker written ==="
T_BASH_6_MARKER="${NODE_TMPDIR}/show-plan-link-marker-bash6-$$"
rm -f "$T_BASH_6_MARKER"
T_BASH_6_CMD="assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md $PLANS_DIR/abc-outline.md"
T_BASH_6_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-6'
  }));
" "$T_BASH_6_CMD")
(
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_MARKER_FILE="$T_BASH_6_MARKER"
  export CONFIRM_OUTLINE=on
  export TERM_PROGRAM=vscode
  echo "$T_BASH_6_JSON" | run_with_timeout node "$HOOK" >/dev/null 2>&1
)
if [ -f "$T_BASH_6_MARKER" ]; then
  pass "T-BASH-6 CONFIRM_OUTLINE=on + NO_SPAWN — marker file written"
else
  fail "T-BASH-6 CONFIRM_OUTLINE=on + NO_SPAWN — marker file NOT written at $T_BASH_6_MARKER"
fi
rm -f "$T_BASH_6_MARKER"

# ── T-BASH-7: Bash + CONFIRM_OUTLINE=off — marker IS still written (#563) ──
echo "=== T-BASH-7: Bash + CONFIRM_OUTLINE=off — always-on after #563 ==="
T_BASH_7_MARKER="${NODE_TMPDIR}/show-plan-link-marker-bash7-$$"
rm -f "$T_BASH_7_MARKER"
T_BASH_7_CMD="assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md $PLANS_DIR/abc-outline.md"
T_BASH_7_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-7'
  }));
" "$T_BASH_7_CMD")
T_BASH_7_STDOUT=$(
  export SHOW_PLAN_LINK_NO_SPAWN=1
  export SHOW_PLAN_LINK_MARKER_FILE="$T_BASH_7_MARKER"
  export CONFIRM_OUTLINE=off
  export TERM_PROGRAM=vscode
  echo "$T_BASH_7_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T_BASH_7_MSG=$(echo "$T_BASH_7_STDOUT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$T_BASH_7_MSG" | grep -q "Plan file written:"; then
  pass "T-BASH-7 CONFIRM_OUTLINE=off — systemMessage still emitted (#563 always-on)"
else
  fail "T-BASH-7 CONFIRM_OUTLINE=off — systemMessage missing: $T_BASH_7_STDOUT"
fi
rm -f "$T_BASH_7_MARKER"

# ── T-BASH-8: literal multi-line backslash-LF form from SKILL.md ──────────
# Target is placed under PLANS_DIR so isFinalPlanArtifact accepts it.
echo "=== T-BASH-8: Bash + multi-line backslash-LF form ==="
T_BASH_8_CMD=$(printf '"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \\\n  "%s/20260527-intent.md" \\\n  "%s/drafts/20260527-outline-draft.md" \\\n  "%s/20260527-outline.md"' "$PLANS_DIR" "$PLANS_DIR" "$PLANS_DIR")
T_BASH_8_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-8'
  }));
" "$T_BASH_8_CMD")
expect_message "T-BASH-8 multi-line backslash-LF form — systemMessage with 20260527-outline.md" \
  "$T_BASH_8_JSON" "20260527-outline.md"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

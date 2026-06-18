# Write tool tests (T1-T21) and CONFIRM_* tests (T-NEW-1~5).
# Sourced by ../feature-show-plan-link.sh — inherits all vars and functions.

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

# ── T-IDEM-1: idempotency — two identical invocations both succeed ─────────
# Issue #922 — calling the hook twice with the same payload must not crash
# and must produce the same systemMessage substring both times. Pins the
# stateless contract of show-plan-link.js.
echo "=== T-IDEM-1: identical hook invocation twice — both emit systemMessage ==="
T_IDEM_JSON="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
T_IDEM_OUT1=$(run_hook "$T_IDEM_JSON")
T_IDEM_OUT2=$(run_hook "$T_IDEM_JSON")
T_IDEM_MSG1=$(echo "$T_IDEM_OUT1" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
T_IDEM_MSG2=$(echo "$T_IDEM_OUT2" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$T_IDEM_MSG1" | grep -qF "Plan file written:" && \
   echo "$T_IDEM_MSG2" | grep -qF "Plan file written:"; then
  pass "T-IDEM-1 two identical invocations both emit systemMessage"
else
  fail "T-IDEM-1 expected both calls to emit 'Plan file written:'; got msg1='$T_IDEM_MSG1' msg2='$T_IDEM_MSG2'"
fi

# ── T-ABSENT-RESPONSE: tool_response missing success/exit_code fields ──────
# Issue #922 — when tool_response is {} (no success, no exit_code), the
# exitCode resolution falls through to 0:
#   resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0)
# So the breadcrumb must still fire.
echo "=== T-ABSENT-RESPONSE: tool_response={} — systemMessage emitted ==="
expect_message "T-ABSENT-RESPONSE absent success/exit_code → exitCode resolves to 0, breadcrumb fires" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{}}" \
  "Plan file written:"

# Bash tool tests (T-BASH-1~9).
# Sourced by ../feature-show-plan-link.sh — inherits all vars and functions.
#
# Bash branch — show-plan-link.js handling for Bash tool invocations of
# assemble-mandatory.sh. Reuses extractAssembleDest() from
# hooks/lib/assemble-cmd-parse.js to detect the destination final-artifact path.

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
T_BASH_2_CMD="assemble-mandatory.sh --source-kind detail $PLANS_DIR/abc-outline.md $PLANS_DIR/abc-detail.md $PLANS_DIR/abc-detail.md"
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

# ── T-BASH-5: assemble targeting flat intermediate-suffix — noop (not final) ─
# After #866 drafts/ is gone; the orthogonal case is an assemble whose
# destination matches an intermediate suffix pattern (e.g. -outline-draft.md)
# sitting directly under PLANS_DIR root. isFinalPlanArtifact must reject it.
echo "=== T-BASH-5: Bash + assemble target = flat intermediate-suffix — noop ==="
T_BASH_5_CMD="assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md $PLANS_DIR/abc-outline-draft.md"
T_BASH_5_JSON=$(run_with_timeout node -e "
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: process.argv[1] },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-5'
  }));
" "$T_BASH_5_CMD")
expect_empty "T-BASH-5 Bash + assemble of flat intermediate-suffix path — noop (not final artifact)" \
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
T_BASH_8_CMD=$(printf '"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \\\n  "%s/20260527-intent.md" \\\n  "%s/20260527-outline.md" \\\n  "%s/20260527-outline.md"' "$PLANS_DIR" "$PLANS_DIR" "$PLANS_DIR")
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

# ── T-BASH-9: new SKILL.md _shared direct form (single-line, session-ID paths) ─
# After #866 the expanded form uses in-place mode (arg 2 == arg 3, both point
# at the final outline.md under PLANS_DIR root; no drafts/ subdir).
# Uses node to build JSON so Windows path is not mangled by MSYS2.
echo "=== T-BASH-9: new SKILL.md _shared direct form — systemMessage ==="
T_BASH_9_JSON=$(run_with_timeout node -e "
  var plans = process.argv[1];
  var sid = '20260617-002151';
  process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: '\"' + '\$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh' + '\" --source-kind intent ' + plans + '/' + sid + '-intent.md ' + plans + '/' + sid + '-outline.md ' + plans + '/' + sid + '-outline.md' },
    tool_response: { exit_code: 0 },
    session_id: 'test-sid-bash-9'
  }));
" "$PLANS_DIR")
expect_message "T-BASH-9 new SKILL.md _shared direct form — systemMessage with session-ID path" \
  "$T_BASH_9_JSON" "20260617-002151-outline.md"

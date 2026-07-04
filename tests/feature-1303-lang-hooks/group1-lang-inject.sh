# group1-lang-inject.sh — G1-T1..T8: hooks/lang-inject.js (UserPromptSubmit) spawn tests.
# Sourced after helpers.sh; inherits all variables and functions.

# ============================================================================
# Group 1: hooks/lang-inject.js (UserPromptSubmit)
# ============================================================================

echo "=== Group 1: hooks/lang-inject.js (UserPromptSubmit) ==="

if [ ! -f "$LANG_INJECT_HOOK" ]; then
    skip "G1: hooks/lang-inject.js not found (RED — not implemented yet)"
else
    # State fixtures
    SID_PLANNING="1303-planning-$$"
    WF_PLANNING="$TMPDIR_BASE/wf-planning"
    build_state "$SID_PLANNING" "$WF_PLANNING" '{}'
    WF_PLANNING_NODE="$(to_node_path "$WF_PLANNING")"

    SID_DONE="1303-done-$$"
    WF_DONE="$TMPDIR_BASE/wf-done"
    build_state "$SID_DONE" "$WF_DONE" \
        '{"clarify_intent":"complete","outline":"complete","detail":"complete"}'
    WF_DONE_NODE="$(to_node_path "$WF_DONE")"

    # G1-T1: planning + CONV_LANG + PLAN_LANG → both lines in additionalContext
    _raw1=$(printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        CONV_LANG=japanese PLAN_LANG=english \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)
    _ctx1=$(extract_additional_context "$_raw1")
    _ok1=1
    echo "$_ctx1" | grep -qF "Respond to the user in japanese" || _ok1=0
    echo "$_ctx1" | grep -qF "Write planning artifacts" || _ok1=0
    echo "$_ctx1" | grep -qF "between tool calls" || _ok1=0
    if [ "$_ok1" -eq 1 ]; then
        pass "G1-T1: planning + CONV_LANG + PLAN_LANG → both lines in additionalContext"
    else
        fail "G1-T1: expected both CONV_LANG + PLAN_LANG lines. ctx='$_ctx1'"
    fi

    # G1-T2: planning complete + CONV_LANG + PLAN_LANG → only CONV_LANG (no PLAN_LANG)
    _raw2=$(printf "{\"session_id\":\"$SID_DONE\"}" | \
        CONV_LANG=japanese PLAN_LANG=english \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_DONE_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)
    _ctx2=$(extract_additional_context "$_raw2")
    _ok2=1
    echo "$_ctx2" | grep -qF "Respond to the user in japanese" || _ok2=0
    echo "$_ctx2" | grep -qF "Write planning artifacts" && _ok2=0
    if [ "$_ok2" -eq 1 ]; then
        pass "G1-T2: planning complete → CONV_LANG present, PLAN_LANG absent"
    else
        fail "G1-T2: unexpected content. ctx='$_ctx2'"
    fi

    # G1-T3: CONV_LANG unset + planning + PLAN_LANG → only PLAN_LANG line
    _raw3=$(printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        PLAN_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node -e "
delete process.env.CONV_LANG;
const { execFileSync } = require('child_process');
// Note: run hook as child to inherit env cleanly
" 2>/dev/null; \
        (unset CONV_LANG; printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        PLAN_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null))
    _ctx3=$(extract_additional_context "$_raw3")
    _ok3=1
    echo "$_ctx3" | grep -qF "Write planning artifacts" || _ok3=0
    echo "$_ctx3" | grep -qF "Respond to the user in" && _ok3=0
    if [ "$_ok3" -eq 1 ]; then
        pass "G1-T3: CONV_LANG unset + planning → only PLAN_LANG line"
    else
        fail "G1-T3: unexpected content. ctx='$_ctx3'"
    fi

    # G1-T4: both unset → output is {} (no injection)
    _raw4=$( (unset CONV_LANG; unset PLAN_LANG; printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null) )
    if [ "$_raw4" = "{}" ]; then
        pass "G1-T4: both unset → output is {}"
    else
        _ctx4=$(extract_additional_context "$_raw4")
        if [ -z "$_ctx4" ]; then
            pass "G1-T4: both unset → empty additionalContext"
        else
            fail "G1-T4: expected {}, got '$_raw4'"
        fi
    fi

    # G1-T5: session_id missing → fail-open, exit 0, valid JSON
    _raw5=$(printf '{}' | \
        CONV_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)
    _rc5=$?
    _valid5=$(is_valid_hook_output "$_raw5")
    if [ "$_rc5" -eq 0 ] && [ "$_valid5" = "yes" ]; then
        pass "G1-T5: session_id absent → fail-open, exit 0, valid JSON"
    else
        fail "G1-T5: expected exit 0 + valid JSON. rc=$_rc5 valid=$_valid5 raw='$_raw5'"
    fi

    # G1-T6: malformed stdin → exit 0, valid JSON
    _raw6=$(printf 'not-json' | \
        CONV_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)
    _rc6=$?
    _valid6=$(is_valid_hook_output "$_raw6")
    if [ "$_rc6" -eq 0 ] && [ "$_valid6" = "yes" ]; then
        pass "G1-T6: malformed stdin → valid JSON output, exit 0 (fail-open)"
    else
        fail "G1-T6: expected exit 0 + valid JSON. rc=$_rc6 raw='$_raw6'"
    fi

    # G1-T7: output shape has hookSpecificOutput.hookEventName=UserPromptSubmit
    _raw7=$(printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        CONV_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)
    _event7=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write((o.hookSpecificOutput || {}).hookEventName || '');
} catch (e) { process.stdout.write(''); }
" "$_raw7" 2>/dev/null)
    if [ "$_event7" = "UserPromptSubmit" ]; then
        pass "G1-T7: hookSpecificOutput.hookEventName = 'UserPromptSubmit'"
    else
        fail "G1-T7: expected hookEventName='UserPromptSubmit', got '$_event7'. raw='$_raw7'"
    fi

    # G1-T8 [Idempotency]: two identical invocations → byte-identical, non-empty,
    # CONV_LANG directive present. Mirrors the session-start/post-compact idempotency
    # shape (fix-conv-lang-inject T18/T19). Same stdin + planning state + CONV_LANG.
    #
    # False-green guard: equality alone is insufficient — in the RED state the hook
    # is absent and both runs emit identical empty output ("" == ""), which would
    # spuriously PASS. We therefore also assert the additionalContext is NON-EMPTY
    # and contains the CONV_LANG directive substring. Both extra assertions fail in
    # RED (hook not implemented → no directive), so this only passes post-implementation.
    _idem_ctx_a=$(extract_additional_context "$(printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        CONV_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)")
    _idem_ctx_b=$(extract_additional_context "$(printf "{\"session_id\":\"$SID_PLANNING\"}" | \
        CONV_LANG=japanese \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WF_PLANNING_NODE" \
        run_with_timeout 15 node "$LANG_INJECT_HOOK" 2>/dev/null)")
    _idem_ok=1
    [ "$_idem_ctx_a" = "$_idem_ctx_b" ] || _idem_ok=0
    [ -n "$_idem_ctx_a" ] || _idem_ok=0
    echo "$_idem_ctx_a" | grep -qF "Respond to the user in japanese" || _idem_ok=0
    if [ "$_idem_ok" -eq 1 ]; then
        pass "G1-T8: lang-inject.js is idempotent (byte-identical, non-empty, CONV_LANG directive present)"
    else
        fail "G1-T8: idempotency/content check failed. equal=$([ "$_idem_ctx_a" = "$_idem_ctx_b" ] && echo yes || echo no) ctxA='$_idem_ctx_a'"
    fi
fi

echo ""

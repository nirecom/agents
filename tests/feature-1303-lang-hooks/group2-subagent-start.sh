# group2-subagent-start.sh — G2-T1..T8: hooks/subagent-start.js PLAN_LANG whitelist (C3).
# Sourced after helpers.sh; inherits all variables and functions.

# ============================================================================
# Group 2: hooks/subagent-start.js PLAN_LANG whitelist (C3)
# ============================================================================

echo "=== Group 2: hooks/subagent-start.js PLAN_LANG whitelist ==="

if [ ! -f "$SUBAGENT_START_HOOK" ]; then
    skip "G2: hooks/subagent-start.js not found"
else
    PLAN_INJECT_PREFIX="Write planning artifacts"
    CONV_INJECT_PREFIX="Respond to the user in"

    # Helper: invoke subagent-start with given stdin JSON and env vars
    invoke_subagent() {
        local stdin_json="$1" conv_lang="${2-}" plan_lang="${3-}"
        if [ -n "$conv_lang" ] && [ -n "$plan_lang" ]; then
            printf '%s' "$stdin_json" | \
                CONV_LANG="$conv_lang" PLAN_LANG="$plan_lang" \
                AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
                run_with_timeout 15 node "$SUBAGENT_START_HOOK" 2>/dev/null
        elif [ -n "$conv_lang" ]; then
            printf '%s' "$stdin_json" | \
                (unset PLAN_LANG; CONV_LANG="$conv_lang" \
                AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
                run_with_timeout 15 node "$SUBAGENT_START_HOOK" 2>/dev/null)
        elif [ -n "$plan_lang" ]; then
            printf '%s' "$stdin_json" | \
                (unset CONV_LANG; PLAN_LANG="$plan_lang" \
                AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
                run_with_timeout 15 node "$SUBAGENT_START_HOOK" 2>/dev/null)
        else
            printf '%s' "$stdin_json" | \
                (unset CONV_LANG; unset PLAN_LANG; \
                AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
                run_with_timeout 15 node "$SUBAGENT_START_HOOK" 2>/dev/null)
        fi
    }

    # G2-T1: detail-planner + PLAN_LANG → PLAN_LANG + CONV_LANG lines
    _raw_s1=$(invoke_subagent '{"agent_type":"detail-planner"}' "japanese" "english")
    _ctx_s1=$(extract_subagent_ctx "$_raw_s1")
    _ok_s1=1
    echo "$_ctx_s1" | grep -qF "$PLAN_INJECT_PREFIX" || _ok_s1=0
    echo "$_ctx_s1" | grep -qF "$CONV_INJECT_PREFIX" || _ok_s1=0
    if [ "$_ok_s1" -eq 1 ]; then
        pass "G2-T1: agent_type=detail-planner + PLAN_LANG → PLAN_LANG + CONV_LANG lines"
    else
        fail "G2-T1: expected both lines. ctx='$_ctx_s1'"
    fi

    # G2-T2: outline-planner → PLAN_LANG present
    _raw_s2=$(invoke_subagent '{"agent_type":"outline-planner"}' "japanese" "english")
    _ctx_s2=$(extract_subagent_ctx "$_raw_s2")
    if echo "$_ctx_s2" | grep -qF "$PLAN_INJECT_PREFIX"; then
        pass "G2-T2: agent_type=outline-planner → PLAN_LANG line present"
    else
        fail "G2-T2: outline-planner should get PLAN_LANG. ctx='$_ctx_s2'"
    fi

    # G2-T3: outline-reviewer → PLAN_LANG present
    _raw_s3=$(invoke_subagent '{"agent_type":"outline-reviewer"}' "japanese" "english")
    _ctx_s3=$(extract_subagent_ctx "$_raw_s3")
    if echo "$_ctx_s3" | grep -qF "$PLAN_INJECT_PREFIX"; then
        pass "G2-T3: agent_type=outline-reviewer → PLAN_LANG line present"
    else
        fail "G2-T3: outline-reviewer should get PLAN_LANG. ctx='$_ctx_s3'"
    fi

    # G2-T4: detail-reviewer → PLAN_LANG present
    _raw_s4=$(invoke_subagent '{"agent_type":"detail-reviewer"}' "japanese" "english")
    _ctx_s4=$(extract_subagent_ctx "$_raw_s4")
    if echo "$_ctx_s4" | grep -qF "$PLAN_INJECT_PREFIX"; then
        pass "G2-T4: agent_type=detail-reviewer → PLAN_LANG line present"
    else
        fail "G2-T4: detail-reviewer should get PLAN_LANG. ctx='$_ctx_s4'"
    fi

    # G2-T5: commit-push-worker (not in whitelist) → PLAN_LANG absent, CONV_LANG present
    _raw_s5=$(invoke_subagent '{"agent_type":"commit-push-worker"}' "japanese" "english")
    _ctx_s5=$(extract_subagent_ctx "$_raw_s5")
    _ok_s5=1
    echo "$_ctx_s5" | grep -qF "$PLAN_INJECT_PREFIX" && _ok_s5=0
    echo "$_ctx_s5" | grep -qF "$CONV_INJECT_PREFIX" || _ok_s5=0
    if [ "$_ok_s5" -eq 1 ]; then
        pass "G2-T5: commit-push-worker → PLAN_LANG absent, CONV_LANG present"
    else
        fail "G2-T5: unexpected content. ctx='$_ctx_s5'"
    fi

    # G2-T6: agent_type missing → PLAN_LANG absent
    _raw_s6=$(invoke_subagent '{}' "japanese" "english")
    _ctx_s6=$(extract_subagent_ctx "$_raw_s6")
    if echo "$_ctx_s6" | grep -qF "$PLAN_INJECT_PREFIX"; then
        fail "G2-T6: agent_type absent should NOT get PLAN_LANG. ctx='$_ctx_s6'"
    else
        pass "G2-T6: agent_type absent → PLAN_LANG absent (fail-open)"
    fi

    # G2-T7: CONV_LANG maintained for non-whitelisted agent (regression)
    _raw_s7=$(invoke_subagent '{"agent_type":"security-scanner"}' "japanese" "")
    _ctx_s7=$(extract_subagent_ctx "$_raw_s7")
    if echo "$_ctx_s7" | grep -qF "$CONV_INJECT_PREFIX"; then
        pass "G2-T7: non-whitelist agent still receives CONV_LANG (regression)"
    else
        fail "G2-T7: CONV_LANG missing for non-whitelist agent. ctx='$_ctx_s7'"
    fi

    # G2-T8: malformed stdin → fail-open, exit 0, valid JSON
    _raw_s8=$(printf 'not-json' | \
        CONV_LANG=japanese PLAN_LANG=english \
        AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        run_with_timeout 15 node "$SUBAGENT_START_HOOK" 2>/dev/null)
    _rc_s8=$?
    _valid_s8=$(is_valid_hook_output "$_raw_s8")
    if [ "$_rc_s8" -eq 0 ] && [ "$_valid_s8" = "yes" ]; then
        pass "G2-T8: malformed stdin → fail-open, exit 0, valid JSON"
    else
        fail "G2-T8: rc=$_rc_s8 valid=$_valid_s8 raw='$_raw_s8'"
    fi
fi

echo ""

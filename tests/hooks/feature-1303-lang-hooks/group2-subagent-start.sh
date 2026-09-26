# group2-subagent-start.sh — G2-T1..T16: hooks/subagent-start.js PLAN_LANG injection
# Tests: hooks/subagent-start.js
# Tags: hook-injection, subagent-start, plan-lang, pwsh-not-required, scope:issue-specific
# (whitelist retired in #2278: every agent type receives it when the policy is strict).
# Sourced after helpers.sh; inherits all variables and functions.

# ============================================================================
# Group 2: hooks/subagent-start.js PLAN_LANG injection (all agents, #2278)
# ============================================================================

echo "=== Group 2: hooks/subagent-start.js PLAN_LANG injection ==="

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

    # G2-T5: #2278 retired the PLAN_AGENTS whitelist — ANY agent type receives the
    # PLAN_LANG line when the policy is strict, alongside CONV_LANG.
    # issue-create-survey-worker is a non-planner agent (the former negative case).
    _raw_s5=$(invoke_subagent '{"agent_type":"issue-create-survey-worker"}' "japanese" "english")
    _ctx_s5=$(extract_subagent_ctx "$_raw_s5")
    _ok_s5=1
    echo "$_ctx_s5" | grep -qF "$PLAN_INJECT_PREFIX" || _ok_s5=0
    echo "$_ctx_s5" | grep -qF "$CONV_INJECT_PREFIX" || _ok_s5=0
    if [ "$_ok_s5" -eq 1 ]; then
        pass "G2-T5: any agent type receives PLAN_LANG when policy is strict (issue-create-survey-worker) + CONV_LANG"
    else
        fail "G2-T5: expected PLAN_LANG + CONV_LANG lines for a non-planner agent. ctx='$_ctx_s5'"
    fi

    # G2-T6: agent_type missing → PLAN_LANG still injected (payload-independent, #2278)
    _raw_s6=$(invoke_subagent '{}' "japanese" "english")
    _ctx_s6=$(extract_subagent_ctx "$_raw_s6")
    if echo "$_ctx_s6" | grep -qF "$PLAN_INJECT_PREFIX"; then
        pass "G2-T6: agent_type absent → PLAN_LANG present (injection does not depend on the payload)"
    else
        fail "G2-T6: agent_type absent should still get PLAN_LANG. ctx='$_ctx_s6'"
    fi

    # G2-T11/T12 (#2278): the complete injected directive equals what the SSOT
    # getPlanLangInjection() (hooks/lib/lang-config.js) returns for japanese —
    # full-line match, not just the prefix. (a) non-whitelisted agent, (b) no agent_type.
    _plan_full_ja="$( (unset CONV_LANG; PLAN_LANG=japanese AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        run_with_timeout 15 node -e "process.stdout.write(String(require('$AGENTS_DIR/hooks/lib/lang-config.js').getPlanLangInjection()))" 2>/dev/null) )"
    if [ -z "$_plan_full_ja" ] || [ "$_plan_full_ja" = "null" ]; then
        fail "G2-T11/T12 precondition: getPlanLangInjection() returned '$_plan_full_ja' for japanese"
    else
        _raw_s11=$(invoke_subagent '{"agent_type":"issue-create-survey-worker"}' "japanese" "japanese")
        _ctx_s11=$(extract_subagent_ctx "$_raw_s11")
        if printf '%s\n' "$_ctx_s11" | grep -qxF -- "$_plan_full_ja"; then
            pass "G2-T11: issue-create-survey-worker + PLAN_LANG=japanese → full directive line == '$_plan_full_ja'"
        else
            fail "G2-T11: expected a line exactly '$_plan_full_ja'. ctx='$_ctx_s11'"
        fi
        _raw_s12=$(invoke_subagent '{}' "japanese" "japanese")
        _ctx_s12=$(extract_subagent_ctx "$_raw_s12")
        if printf '%s\n' "$_ctx_s12" | grep -qxF -- "$_plan_full_ja"; then
            pass "G2-T12: agent_type absent + PLAN_LANG=japanese → full directive line == '$_plan_full_ja'"
        else
            fail "G2-T12: expected a line exactly '$_plan_full_ja'. ctx='$_ctx_s12'"
        fi
    fi

    # G2-T13/T14 (#2278): hint tier (PLAN_LANG=french) is injected the same way —
    # the full line must equal getPlanLangInjection() for french, whitelist or not.
    _plan_full_fr="$( (unset CONV_LANG; PLAN_LANG=french AGENTS_CONFIG_DIR="$EMPTY_DIR_NODE" \
        run_with_timeout 15 node -e "process.stdout.write(String(require('$AGENTS_DIR/hooks/lib/lang-config.js').getPlanLangInjection()))" 2>/dev/null) )"
    if [ -z "$_plan_full_fr" ] || [ "$_plan_full_fr" = "null" ] || [ "$_plan_full_fr" = "$_plan_full_ja" ]; then
        fail "G2-T13/T14 precondition: getPlanLangInjection() returned '$_plan_full_fr' for french"
    else
        _raw_s13=$(invoke_subagent '{"agent_type":"issue-create-survey-worker"}' "japanese" "french")
        _ctx_s13=$(extract_subagent_ctx "$_raw_s13")
        if printf '%s\n' "$_ctx_s13" | grep -qxF -- "$_plan_full_fr"; then
            pass "G2-T13: issue-create-survey-worker + PLAN_LANG=french → full hint line == '$_plan_full_fr'"
        else
            fail "G2-T13: expected a line exactly '$_plan_full_fr'. ctx='$_ctx_s13'"
        fi
        _raw_s14=$(invoke_subagent '{}' "japanese" "french")
        _ctx_s14=$(extract_subagent_ctx "$_raw_s14")
        if printf '%s\n' "$_ctx_s14" | grep -qxF -- "$_plan_full_fr"; then
            pass "G2-T14: agent_type absent + PLAN_LANG=french → full hint line == '$_plan_full_fr'"
        else
            fail "G2-T14: expected a line exactly '$_plan_full_fr'. ctx='$_ctx_s14'"
        fi
    fi

    # G2-T15/T16 (#2278 C5) — both need the japanese SSOT line computed above.
    if [ -n "$_plan_full_ja" ] && [ "$_plan_full_ja" != "null" ]; then
        # G2-T15: malformed stdin JSON. subagent-start.js treats a parse error as {}
        # (agentType undefined) and still reaches the injection block, so the
        # payload-independent directive must be present under a strict policy.
        _raw_s15=$(invoke_subagent 'not-json' "japanese" "japanese")
        _ctx_s15=$(extract_subagent_ctx "$_raw_s15")
        if printf '%s\n' "$_ctx_s15" | grep -qxF -- "$_plan_full_ja"; then
            pass "G2-T15: malformed stdin + PLAN_LANG=japanese → directive line still injected (parse error ≡ {})"
        else
            fail "G2-T15: expected a line exactly '$_plan_full_ja' on malformed stdin. ctx='$_ctx_s15'"
        fi
        # G2-T16: planner agent receives the directive exactly once — a retained
        # whitelist branch plus the unconditional push would duplicate it.
        _raw_s16=$(invoke_subagent '{"agent_type":"detail-planner"}' "japanese" "japanese")
        _ctx_s16=$(extract_subagent_ctx "$_raw_s16")
        _n_s16=$(printf '%s\n' "$_ctx_s16" | grep -cF -- "$PLAN_INJECT_PREFIX")
        if [ "$_n_s16" = "1" ]; then
            pass "G2-T16: detail-planner + PLAN_LANG=japanese → exactly one '$PLAN_INJECT_PREFIX' line"
        else
            fail "G2-T16: expected exactly 1 directive line, got $_n_s16. ctx='$_ctx_s16'"
        fi
    fi

    # G2-T9: PLAN_LANG unset → no PLAN_LANG line (noop tier), CONV_LANG still present
    _raw_s9=$(invoke_subagent '{"agent_type":"issue-create-survey-worker"}' "japanese" "")
    _ctx_s9=$(extract_subagent_ctx "$_raw_s9")
    _ok_s9=1
    echo "$_ctx_s9" | grep -qF "$PLAN_INJECT_PREFIX" && _ok_s9=0
    echo "$_ctx_s9" | grep -qF "$CONV_INJECT_PREFIX" || _ok_s9=0
    if [ "$_ok_s9" -eq 1 ]; then
        pass "G2-T9: PLAN_LANG unset → no PLAN_LANG line, CONV_LANG present"
    else
        fail "G2-T9: expected CONV_LANG only. ctx='$_ctx_s9'"
    fi

    # G2-T10: PLAN_LANG=any → no PLAN_LANG line (noop tier)
    _raw_s10=$(invoke_subagent '{"agent_type":"detail-planner"}' "japanese" "any")
    _ctx_s10=$(extract_subagent_ctx "$_raw_s10")
    _ok_s10=1
    echo "$_ctx_s10" | grep -qF "$PLAN_INJECT_PREFIX" && _ok_s10=0
    echo "$_ctx_s10" | grep -qF "$CONV_INJECT_PREFIX" || _ok_s10=0
    if [ "$_ok_s10" -eq 1 ]; then
        pass "G2-T10: PLAN_LANG=any → no PLAN_LANG line even for detail-planner, CONV_LANG present"
    else
        fail "G2-T10: expected CONV_LANG only under PLAN_LANG=any. ctx='$_ctx_s10'"
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

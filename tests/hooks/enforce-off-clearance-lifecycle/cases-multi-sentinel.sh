#!/usr/bin/env bash
# Part of tests/enforce-off-clearance-lifecycle.sh (rules/coding/file-split.md).
# Section M - L-1: one tool call may carry at most ONE activating OFF sentinel.
#
# The gate must see exactly the units the ACTIVATION layer sees. hooks/workflow-mark.js
# splits a Bash command on `&&` and dispatches each part, and runCommands runs every
# element of its array - so "the first sentinel in the payload" was never the whole
# story. Two things are asserted, and they are different claims:
#
#   (a) N activating sentinels -> rejected OUTRIGHT, with a message that says so.
#       Not "gated N times": N clearances would have to be bound to N targets and
#       consumed in an order this gate cannot observe.
#   (b) the rejection is INERT - the clearance token is neither claimed nor
#       consumed, so a rejected call costs the session nothing and the follow-up
#       single-sentinel call still works.
#
# LOOKSLIKE (reason-less) forms are deliberately NOT counted: workflow-mark rejects
# them as malformed, so they activate nothing, and counting them would block inert
# text. That exclusion is asserted too - it is the direction a "just count every
# sentinel-looking string" simplification would break.

# _mint <tmp_node> <sid>: a valid, reason-bound, workflow-target clearance token.
_mint() { "$RWT" 15 node "$PROBE" mktoken "$_AGENTS_DIR_NODE" "$1" "$2" workflow workflow-bug >/dev/null 2>&1; }
_count_glob() { local n; n=$(ls -1 $1 2>/dev/null | wc -l); printf '%s' "$(printf '%s' "$n" | tr -d ' ')"; }

run_M_multi_sentinel() {
    local tmp tn cwd r sid

    # --- M1: runCommands array carrying TWO activating sentinels --------------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem1"
    _mint "$tn" "$sid"
    r=$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND" "$WT_BOUND")")
    assert_verdict "M1 runCommands[] with 2 activating OFF sentinels" block "$r"
    case "${r#*|}" in
        *"carries 2 OFF sentinels"*) pass "M1 block message names the multi-sentinel policy" ;;
        *) fail "M1 block message should name the multi-sentinel policy: ${r#*|}" ;;
    esac
    # (b) the rejected call must not have spent the grant.
    assert_eq "M1 bare clearance token survives a rejected multi-sentinel call" "yes" \
        "$([ -f "$tmp/$sid$TOKEN_SUF" ] && echo yes || echo no)"
    assert_eq "M1 no claim file created by a rejected multi-sentinel call" "0" \
        "$(_count_glob "$tmp/*$CLAIMED_SUF")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M2: Bash `a && b` - the same two units, delivered the other way ------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem2"
    _mint "$tn" "$sid"
    assert_verdict "M2 Bash '&&' chaining 2 activating OFF sentinels" block \
        "$(run_shim "$tn" "$cwd" "$(mk_bash_json "$sid" "$WF_BOUND && $WT_BOUND")")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M3: EMERGENCY first, gated OFF second (the smuggling shape) ---------
    # The emergency form exits the gate early by design. When it was allowed to be
    # the adjudicated unit, everything ELSE in the same call rode along un-gated.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem3"
    assert_verdict "M3 EMERGENCY sentinel first + gated OFF second (Phase1 smuggling)" block \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_EMERG" "$WF_BOUND")")"
    assert_verdict "M3b same pair in the other order" block \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND" "$WF_EMERG")")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M4: the SAME sentinel twice still counts as two activations ---------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem4"
    _mint "$tn" "$sid"
    assert_verdict "M4 the same activating sentinel repeated twice" block \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND" "$WF_BOUND")")"
    rm -r -f "$tmp" 2>/dev/null

    # === CPR-ORTH counterparts: everything with ONE activation must still work ===

    # --- M5: single activating sentinel + valid token -> allow, token spent ---
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem5"
    _mint "$tn" "$sid"
    assert_verdict "M5 single activating sentinel with a valid clearance" allow \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND")")"
    assert_eq "M5 bare token consumed on allow" "no" \
        "$([ -f "$tmp/$sid$TOKEN_SUF" ] && echo yes || echo no)"
    assert_eq "M5 exactly one claim file written" "1" "$(_count_glob "$tmp/*$CLAIMED_SUF")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M6: one activating + one LOOKSLIKE -> still ONE activation ----------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem6"
    _mint "$tn" "$sid"
    assert_verdict "M6 activating + reason-less LOOKSLIKE form (LOOKSLIKE activates nothing)" allow \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND" "$WF_LOOK")")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M7: LOOKSLIKE forms only -> nothing to gate, nothing claimed --------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem7"
    _mint "$tn" "$sid"
    assert_verdict "M7 two LOOKSLIKE forms and no activating sentinel" allow \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_LOOK" "$WT_LOOK")")"
    assert_eq "M7 no claim file (nothing was activated, so nothing is spent)" "0" \
        "$(_count_glob "$tmp/*$CLAIMED_SUF")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M8: activating sentinel chained with ordinary commands --------------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem8"
    _mint "$tn" "$sid"
    assert_verdict "M8 one activating sentinel && ordinary commands" allow \
        "$(run_shim "$tn" "$cwd" "$(mk_bash_json "$sid" "$WF_BOUND && echo done && ls")")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M9: EMERGENCY alone still bypasses Phase1 (the escape hatch) --------
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem9"
    assert_verdict "M9 EMERGENCY sentinel alone, no token" allow \
        "$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_EMERG")")"
    rm -r -f "$tmp" 2>/dev/null

    # --- M10: single activating sentinel with NO token -> block, but for the -
    #     ORDINARY reason. A multi-sentinel message here would mean the new policy
    #     had swallowed the pre-existing clearance gate.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); cwd="$tmp"; sid="lifem10"
    r=$(run_shim "$tn" "$cwd" "$(mk_runcommands_json "$sid" "$WF_BOUND")")
    assert_verdict "M10 single activating sentinel without a clearance" block "$r"
    case "${r#*|}" in
        *"OFF sentinels"*) fail "M10 must block for lack of clearance, not as multi-sentinel: ${r#*|}" ;;
        *"clearance"*)     pass "M10 block message is the no-clearance one, not the multi-sentinel one" ;;
        *)                 fail "M10 unexpected block message: ${r#*|}" ;;
    esac
    rm -r -f "$tmp" 2>/dev/null
}

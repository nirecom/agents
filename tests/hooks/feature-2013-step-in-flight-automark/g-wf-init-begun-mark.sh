# g-wf-init-begun-mark.sh — G1-G16: a Skill dispatch of /workflow-init records
# workflow_init in_progress under the lookahead origin (#1633), and that record
# leaves the WI-10 readers exactly where they were.
# Tests: hooks/lib/wf-init-begun-mark.js
# Tags: step-in-flight, posttooluse, automark, wf-init, wi-10-lookahead, regression-1633, scope:issue-specific, pwsh-not-required, TL2
# Sourced by tests/hooks/feature-2013-step-in-flight-automark.sh.

# The begun mark is what the commit gate reads as "the WF has begun"; it must
# not look like real work to adoption, the C4 exemptions, or resume detection.

ADOPT_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt.js"
CURSTEP_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/current-step.js"
DETECT_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/bin/resume-session-detect"
GATE_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-gate.js"

# _g_seed_initial <tmp> <tn> <sid> — the v2 initial state (every step pending).
_g_seed_initial() {
    WORKFLOW_STATE_DIR="$2" WORKFLOW_PLANS_DIR="$2" SID="$3" "$RWT" 15 node -e "
require('$STATEIO_NODE').updateTopLevel(process.env.SID, () => {});" >/dev/null 2>&1
}
_g_seed_none() { : ; }
_g_seed_init_complete() { seed_step "$2" "$3" workflow_init complete; }
_g_seed_corrupt() { printf '{not json' >"$1/$3.json"; }

# _g_eval <tn> <sid> <js> — evaluate with S = the projected state, L = lifecycle.
_g_eval() {
    WORKFLOW_STATE_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
const S = require('$STATEIO_NODE').readState(process.env.SID);
const L = require('$LIFECYCLE_NODE');
process.stdout.write(String($3));" 2>/dev/null
}

# _g_marked <id> <desc> <sid> <skill> <setup> — workflow_init in_progress, lookahead origin.
_g_marked() {
    local id="$1" desc="$2" sid="$3" skill="$4" setup="$5" tmp tn status origin
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    run_automark "$tn" "$sid" Skill "" "$skill"
    status="$(step_status "$tmp" "$sid" workflow_init)"
    origin="$(_b22_origin "$tn" "$sid" workflow_init)"
    if [ "$AM_RC" -eq 0 ] && [ "$status" = "in_progress" ] && [ "$origin" = "postuse-in-flight/true" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — workflow_init '$status', origin/lookahead-only '$origin', rc=$AM_RC"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

run_G1() { _g_marked G1 "Skill 'workflow-init' on the v2 initial state marks workflow_init in_progress (postuse-in-flight)" g1 workflow-init _g_seed_initial; }
run_G2() { _g_marked G2 "Skill 'wf-init' marks workflow_init the same way" g2 wf-init _g_seed_initial; }
run_G3() { _g_marked G3 "namespaced Skill 'plugin:workflow-init' marks workflow_init the same way" g3 plugin:workflow-init _g_seed_initial; }
run_G8() { _g_marked G8 "Skill 'workflow-init' with NO state file creates one with workflow_init in_progress" g8 workflow-init _g_seed_none; }

run_G4() {
    local tmp tn first second
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_seed_initial "$tmp" "$tn" g4
    run_automark "$tn" g4 Skill "" workflow-init
    first="$(event_count "$tmp" g4)"
    run_automark "$tn" g4 Skill "" workflow-init
    second="$(event_count "$tmp" g4)"
    if [ "$first" -gt 0 ] && [ "$first" = "$second" ]; then
        pass "G4: a second workflow-init dispatch appends no event (idempotent)"
    else
        fail "G4: event count went $first -> $second across a repeated dispatch"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# _g_unchanged <id> <desc> <sid> <skill> <setup> [agent_id]
_g_unchanged() {
    local id="$1" desc="$2" sid="$3" skill="$4" setup="$5" agent="${6:-}" tmp tn before after
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    before="$(state_digest "$tmp" "$sid")|$(event_count "$tmp" "$sid")"
    run_automark "$tn" "$sid" Skill "$agent" "$skill"
    after="$(state_digest "$tmp" "$sid")|$(event_count "$tmp" "$sid")"
    if [ "$AM_RC" -eq 0 ] && [ "$before" = "$after" ] && [ "${before%%|*}" != "<no-state>" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — '$before' -> '$after', rc=$AM_RC"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

run_G5() { _g_unchanged G5 "workflow-init dispatch with workflow_init already complete leaves the state alone" g5 workflow-init _g_seed_init_complete; }
run_G6() { _g_unchanged G6 "workflow-init dispatch from a subagent turn (agent_id) leaves the state alone" g6 workflow-init _g_seed_initial agent-1; }
run_G9() { _g_unchanged G9 "a non-wf-init Skill (make-outline-plan) on the initial state does nothing" g9 make-outline-plan _g_seed_initial; }

run_G7() {
    local tmp tn before after
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_seed_corrupt "$tmp" "$tn" g7
    before="$(cat "$tmp/g7.json")"
    run_automark "$tn" g7 Skill "" workflow-init
    after="$(cat "$tmp/g7.json" 2>/dev/null)"
    if [ "$AM_RC" -eq 0 ] && [ "$before" = "$after" ]; then
        pass "G7: workflow-init dispatch against a corrupt state file writes nothing"
    else
        fail "G7: corrupt state was touched ('$before' -> '$after'), rc=$AM_RC"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# G10-G16: the begun mark must not move the WI-10 readers.
# _g_begun <tmp> <tn> <sid> — the initial state after a workflow-init dispatch.
_g_begun() {
    _g_seed_initial "$1" "$2" "$3"
    run_automark "$2" "$3" Skill "" workflow-init
}

run_G10() {
    local tmp tn status origin
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_begun "$tmp" "$tn" g10
    run_automark "$tn" g10 Agent
    status="$(step_status "$tmp" g10 research)"
    origin="$(_b22_origin "$tn" g10 research)"
    if [ "$status" = "in_progress" ] && [ "$origin" = "postuse-in-flight/true" ]; then
        pass "G10: with workflow_init begun, an Agent dispatch still marks research (WI-10 lookahead)"
    else
        fail "G10: research '$status', origin '$origin' after the Agent dispatch"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# _g_reader <id> <desc> <want> <js> — one reader over the begun state.
_g_reader() {
    local id="$1" desc="$2" want="$3" js="$4" tmp tn got
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_begun "$tmp" "$tn" "$id"
    got="$(_g_eval "$tn" "$id" "$js")"
    if [ "$got" = "$want" ]; then pass "$id: $desc"; else fail "$id: $desc — got '${got:-<eval-error>}', want '$want'"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

run_G11() { _g_reader G11 "resolveCurrentEffectiveStep still returns workflow_init" workflow_init \
    "require('$CURSTEP_NODE').resolveCurrentEffectiveStep(process.env.SID)"; }
run_G12() { _g_reader G12 "adopt.isAllPending stays true (adoption is not refused)" true \
    "require('$ADOPT_NODE').isAllPending(S)"; }
run_G13() { _g_reader G13 "lifecycle.isWorkflowStarted stays false" false \
    "L.isWorkflowStarted(process.env.SID)"; }

run_G14() {
    local tmp tn repo out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_begun "$tmp" "$tn" g14
    repo="$tmp/repo"; make_repo_fixture "$repo"
    # The target sits outside the OS temp dir: the early-gate write allowlist
    # (scratchpad) would otherwise clear any path under the mktemp fixture.
    out="$(printf '{"tool_name":"Edit","session_id":"g14","tool_input":{"file_path":"/c/git/g14-proj/src/foo.js","old_string":"a","new_string":"b"}}' \
        | (cd "$tmp" && WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_PROJECT_DIR="$(node_path "$repo")" "$RWT" 20 node "$GATE_NODE") 2>/dev/null)"
    case "$out" in
        *'"decision":"block"'*"workflow_init has not been completed"*)
            pass "G14: early-gate still blocks Edit at Tier 1 with workflow_init begun" ;;
        *) fail "G14: Edit was not blocked at Tier 1 — got '${out:0:300}'" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
}

run_G15() {
    local tmp tn got
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_begun "$tmp" "$tn" g15
    backdate_step "$tmp" g15 workflow_init $((TTL_MS + 60000))
    got="$(_g_eval "$tn" g15 "L.isLookaheadOnlyInFlight(process.env.SID, 'workflow_init')")"
    if [ "$got" = "true" ]; then
        pass "G15: a workflow_init begun mark past the TTL is still lookahead-only (stays exempt)"
    else
        fail "G15: isLookaheadOnlyInFlight for an aged workflow_init mark is '$got'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# _g_detect <tn> <sid> — bin/resume-session-detect's detect(), as "type:skill".
_g_detect() {
    WORKFLOW_STATE_DIR="$1" WORKFLOW_PLANS_DIR="$1" CLAUDE_CODE_SESSION_ID="$2" CLAUDE_TRANSCRIPT_BASE_DIR="" "$RWT" 20 node -e "
const r = require('$DETECT_NODE').detect();
process.stdout.write(String(r && r.type) + ':' + String((r && r.skill) || '-'));" 2>/dev/null
}

run_G16() {
    local tmp tn first second
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _g_begun "$tmp" "$tn" g16
    first="$(_g_detect "$tn" g16)"
    run_automark "$tn" g16 Agent
    second="$(_g_detect "$tn" g16)"
    if [ "$first" = "skill:workflow-init" ] && [ "$second" = "skill:workflow-init" ]; then
        pass "G16: resume-session-detect routes a begun workflow_init (with or without lookahead research) to workflow-init"
    else
        fail "G16: detect gave '$first' (workflow_init only) and '$second' (plus lookahead research)"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

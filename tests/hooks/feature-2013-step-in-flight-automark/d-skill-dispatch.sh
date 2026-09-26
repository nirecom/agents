# d-skill-dispatch.sh — B13-B21: the Skill-tool dimension of the WI-10
# lookahead (#2279). Sourced by tests/hooks/feature-2013-step-in-flight-automark.sh.
# Tests: hooks/postuse-step-in-flight-mark.js, hooks/stop-confirm-plan-guard.js, settings.json
# Tags: step-in-flight, posttooluse, automark, wi-10-lookahead, skill-dispatch, resume-session, regression-2279, scope:issue-specific, pwsh-not-required, TL2

# #2279: the Skill call that invokes /resume-session itself fires PostToolUse,
# the lookahead marks `research`, and the adoption readers then see a session
# that is no longer "untouched" — the dispatch meant to RESTORE state is what
# disqualifies the session from receiving it. Split out of b-posttooluse.sh
# (already 265 lines) per rules/coding/file-split.md Pattern A.

# _skill_setup_none / _skill_setup_all_pending / _skill_setup_review_tests.
_skill_setup_none() { : ; }   # deliberately no state file at all
# the crash-resume heir shell: a state file that EXISTS and records only pending
_skill_setup_all_pending() { seed_step "$2" "$3" research pending; }
_skill_setup_review_tests() {
    settle_through "$2" "$3" workflow_init clarify_intent research outline detail \
        branching_complete write_tests
}

# _expect_no_state <id> <desc> <sid> <tool> <skill> — the no-state-file
# counterpart of _expect_unchanged. `state_digest` cannot compare a file that
# never existed, so the observable is that the hook created none: a lookahead
# mark on an absent state file is exactly what WRITES the first state file.
_expect_no_state() {
    local id="$1" desc="$2" sid="$3" tool="$4" skill="$5" tmp tn after problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_automark "$tn" "$sid" "$tool" "" "$skill"
    after="$(state_digest "$tmp" "$sid")"
    [ "$AM_RC" -eq 0 ] || problems="$problems [hook exited $AM_RC, want 0]"
    [ "$after" = "<no-state>" ] ||
        problems="$problems [the dispatch created a state file: '$after']"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc —$problems"
    fi
}

# _expect_unchanged_skill / _expect_marked_skill — _expect_unchanged and
# _expect_marked with the payload's `tool_input.skill` field filled in.
_expect_unchanged_skill() {
    local id="$1" desc="$2" sid="$3" skill="$4" setup="$5" tmp tn before after problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    before="$(state_digest "$tmp" "$sid")"
    if [ "$before" = "<no-state>" ] || [ -z "$before" ]; then
        fail "$id: $desc — fixture produced no readable state to compare against"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    run_automark "$tn" "$sid" Skill "" "$skill"
    after="$(state_digest "$tmp" "$sid")"
    [ "$AM_RC" -eq 0 ] || problems="$problems [hook exited $AM_RC, want 0]"
    [ "$before" = "$after" ] || problems="$problems [state changed: '$before' -> '$after']"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc —$problems"
    fi
}

_expect_marked_skill() {
    local id="$1" desc="$2" sid="$3" skill="$4" want="$5" setup="$6" tmp tn got
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    "$setup" "$tmp" "$tn" "$sid"
    run_automark "$tn" "$sid" Skill "" "$skill"
    got="$(step_status "$tmp" "$sid" "$want")"
    if [ "$got" = "in_progress" ] && [ "$AM_RC" -eq 0 ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — $want is '$got' (want in_progress), hook rc=$AM_RC out='$AM_OUT'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# B13: the #2279 repro — a fresh session invokes /resume-session via the Skill
#      tool; the dispatch must leave it untouched (it is the meta-operation that
#      adopts state, not a unit of workflow work).
run_B13() {
    _expect_no_state B13 \
        "Skill dispatch of 'resume-session' on a fresh session creates no state (the #2279 repro)" \
        b13 Skill resume-session
}

# B14: the namespaced spelling. Claude Code delivers plugin/personal skills as
#      '<namespace>:<name>', so a whole-string name comparison reproduces #2279
#      for every user whose skills are namespaced.
run_B14() {
    _expect_no_state B14 \
        "Skill dispatch of the namespaced 'personal:resume-session' is excluded too" \
        b14 Skill personal:resume-session
}

# B15: the tool-dimension (D-3) narrowing — the Skill tool never earns the
#      pre-init lookahead promotion, whatever skill it names. A name-only (D-1)
#      fix passes B13/B14 and fails here; that is the distinction it draws.
run_B15() {
    _expect_no_state B15 \
        "Skill dispatch of a non-meta skill on a fresh session also creates no state (D-3 tool narrowing)" \
        b15 Skill make-outline-plan
}

# B16: the non-regression anchor — #2013's own case. A fix that narrowed the
#      lookahead by TOOL alone would take this out with it.
run_B16() { _expect_marked B16 "Agent dispatch with no state file still marks research (the #2013 lookahead, unregressed)" b16 Agent research _skill_setup_none; }

# B17: D-1 outside the pre-init window. /resume-session is a meta-operation at
#      every point of the workflow, so review_tests must not be claimed by it.
run_B17() {
    _expect_unchanged_skill B17 \
        "Skill dispatch of 'resume-session' past WI-10 (current step review_tests) leaves the state untouched" \
        b17 resume-session _skill_setup_review_tests
}

# B18: B4's non-regression re-confirmed with the skill NAME present — the
#      exclusion is keyed on which skill ran, not on the field being there.
run_B18() {
    _expect_marked_skill B18 \
        "Skill dispatch of 'review-tests' still marks review_tests in_progress" \
        b18 review-tests review_tests _skill_setup_review_tests
}

# B19: an unresolvable skill name. Claude Code owns the payload, so `skill` may
#      be absent, wrongly typed or empty on some host version. Deliberately
#      DIRECTION-FREE: whatever the hook decides, it must decide what it decides
#      for an absent field, and exit 0 — asserting a direction would contradict
#      B15 (see the D-1/D-3 note in the report).
_b19_digest() {
    local raw="$1" tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_automark_raw "$tn" "$raw"
    out="$(state_digest "$tmp" b19)|rc=$AM_RC"
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

run_B19() {
    local baseline label raw got problems=""
    baseline="$(_b19_digest '{"tool_name":"Skill","session_id":"b19","transcript_path":""}')"
    case "$baseline" in
        *"|rc=0") : ;;
        *) problems="$problems [baseline (no tool_input at all) exited non-zero: $baseline]" ;;
    esac
    while IFS='|' read -r label raw; do
        label="$(trim "$label")"; raw="$(trim "$raw")"
        case "$label" in ''|'#'*) continue ;; esac
        got="$(_b19_digest "$raw")"
        case "$got" in
            *"|rc=0") : ;;
            *) problems="$problems [$label: hook did not exit 0 — $got]" ;;
        esac
        [ "$got" = "$baseline" ] ||
            problems="$problems [$label: '$got' differs from the field-absent baseline '$baseline']"
    done <<'EOF'
# label            | raw stdin
skill-number       | {"tool_name":"Skill","session_id":"b19","transcript_path":"","tool_input":{"skill":42}}
skill-empty        | {"tool_name":"Skill","session_id":"b19","transcript_path":"","tool_input":{"skill":""}}
skill-object       | {"tool_name":"Skill","session_id":"b19","transcript_path":"","tool_input":{"skill":{"n":"x"}}}
tool-input-null    | {"tool_name":"Skill","session_id":"b19","transcript_path":"","tool_input":null}
tool-input-array   | {"tool_name":"Skill","session_id":"b19","transcript_path":"","tool_input":["resume-session"]}
EOF
    if [ -z "$problems" ]; then
        pass "B19: an unresolvable tool_input.skill exits 0 and behaves exactly as an absent field (no throw, no divergent guess)"
    else
        fail "B19: malformed skill-name payloads are not handled uniformly;$problems"
    fi
}

# B20: registration + field-name agreement, read as data. The hook can only see
#      `tool_input.skill` if settings.json still routes Skill to it AND the field
#      name matches the other in-tree reader of a Skill payload. Static, so no
#      RUN_TL3 host is needed; the TL3 file proves the host sends that shape.
run_B20() {
    local settings guard problems=""
    settings="$AGENTS_DIR/settings.json"
    guard="$AGENTS_DIR/hooks/stop-confirm-plan-guard.js"
    if [ ! -f "$settings" ]; then
        fail "B20: settings.json not found at $settings"
        return
    fi
    grep -q '"matcher": *"[^"]*Skill' "$settings" ||
        problems="$problems [settings.json has no PostToolUse matcher naming Skill]"
    grep -q 'postuse-step-in-flight-mark' "$settings" ||
        problems="$problems [settings.json does not register postuse-step-in-flight-mark.js]"
    if [ ! -f "$guard" ]; then
        problems="$problems [stop-confirm-plan-guard.js not found]"
    else
        grep -q 'input\.skill' "$guard" ||
            problems="$problems [stop-confirm-plan-guard.js no longer reads 'input.skill' — the field name the new exclusion keys on has drifted]"
    fi
    if [ -z "$problems" ]; then
        pass "B20: settings.json still routes Skill to the auto-mark hook, and 'input.skill' is the same field the in-tree Skill-payload reader uses"
    else
        fail "B20: Skill-payload registration/field-name agreement broken;$problems"
    fi
}

# B21: the shape #2279 actually reports. B13 covers "no state file at all", but
#      the heir a crash-resume lands in normally HAS one — an all-pending shell.
#      The hook's own no-state branch cannot help there, so a fix keyed on file
#      absence passes B13 and still promotes `research` here, which is exactly
#      what disqualifies the heir from the adoption the resume was asking for.
run_B21() {
    _expect_unchanged_skill B21 \
        "Skill dispatch of 'resume-session' against an EXISTING all-pending state file leaves research pending" \
        b21 resume-session _skill_setup_all_pending
}

# B22: the POSITIVE side of the D-3 tool narrowing. B13-B15 and B21 all assert
#      that nothing is written, so a narrowing that wrote nothing for ANY tool
#      satisfies every one of them while silently deleting #2013's fix. This row
#      also pins the ORIGIN: the readers that discount the mark (#2279) key on
#      `postuse-in-flight`, so a promotion recorded under markStep's default
#      origin would be indistinguishable from the user's own work.

# "<origin>/<isLookaheadOnlyInFlight>" for the step's LAST step_status event —
# the attribution the discounting readers actually consult.
_b22_origin() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 15 node -e "
const L = require('$LIFECYCLE_NODE');
const { readState } = require('$STATEIO_NODE');
const s = readState('$2');
const evs = ((s && s.events) || []).filter((e) => e && e.kind === 'step_status' && e.step === '$3');
const last = evs.length ? evs[evs.length - 1] : null;
process.stdout.write((last ? String(last.origin) : '<no-event>') + '/' + String(L.isLookaheadOnlyInFlight('$2', '$3')));" 2>/dev/null
}

run_B22() {
    local tool sid tmp tn status got problems=""
    for tool in Agent Task; do
        sid="b22-$tool"
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        run_automark "$tn" "$sid" "$tool"
        status="$(step_status "$tmp" "$sid" research)"
        got="$(_b22_origin "$tn" "$sid" research)"
        [ "$AM_RC" -eq 0 ] || problems="$problems [$tool: hook exited $AM_RC, want 0]"
        [ "$status" = "in_progress" ] ||
            problems="$problems [$tool: research is '$status', want in_progress — the WI-10 lookahead no longer fires (#2013)]"
        [ "$got" = "postuse-in-flight/true" ] ||
            problems="$problems [$tool: origin/lookahead-only is '$got', want 'postuse-in-flight/true']"
        rm -rf "$tmp" 2>/dev/null || true
    done
    if [ -z "$problems" ]; then
        pass "B22: an Agent or Task dispatch on a FRESH session still promotes research to in_progress, stamped with the lookahead origin the #2279 readers discount it by"
    else
        fail "B22: the lookahead promotion is broken or mis-attributed;$problems"
    fi
}

# B23: B22's other substrate. B22 and B16 both dispatch against NO state file,
# so the hook's `hasStateFile === false` branch carries every positive row and
# the `resolveCurrentEffectiveStep() === 'workflow_init'` half of the WI-10
# window is asserted by nothing. B21 reaches that substrate but only for Skill,
# where the correct answer is "leave it alone" — so a narrowing that skipped
# promotion whenever a state file exists passes B13-B22 intact and silently
# ends the lookahead for every fresh session that already ran SessionStart.

# The two fresh-but-file-bearing shapes a real Task dispatch lands on.
_b23_pending_research() { seed_step "$2" "$3" research pending; }
_b23_pending_init() { seed_step "$2" "$3" workflow_init pending; }

run_B23() {
    local tool setup label sid tmp tn status got problems=""
    for tool in Agent Task; do
        for setup in _b23_pending_research _b23_pending_init; do
            label="$tool/${setup#_b23_}"
            sid="b23-$tool-${setup#_b23_}"
            tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
            "$setup" "$tmp" "$tn" "$sid"
            [ "$(step_status "$tmp" "$sid" research)" != "in_progress" ] ||
                problems="$problems [$label: fixture already had research in_progress — nothing is under test]"
            run_automark "$tn" "$sid" "$tool"
            status="$(step_status "$tmp" "$sid" research)"
            got="$(_b22_origin "$tn" "$sid" research)"
            [ "$AM_RC" -eq 0 ] || problems="$problems [$label: hook exited $AM_RC, want 0]"
            [ "$status" = "in_progress" ] ||
                problems="$problems [$label: research is '$status', want in_progress — a subagent dispatch on a session still inside the WI-10 window no longer claims its step]"
            [ "$got" = "postuse-in-flight/true" ] ||
                problems="$problems [$label: origin/lookahead-only is '$got', want 'postuse-in-flight/true']"
            rm -rf "$tmp" 2>/dev/null || true
        done
    done
    if [ -z "$problems" ]; then
        pass "B23: an Agent or Task dispatch against an EXISTING all-pending state file (research pending, and workflow_init pending) still promotes research in_progress under the lookahead origin — the file-bearing half of the WI-10 window"
    else
        fail "B23: the lookahead promotion does not survive a state file that already exists;$problems"
    fi
}

# B24: B19's malformed payloads where the hook can be caught doing the wrong
# thing. B19 runs them on a FRESH session, where the D-3 tool narrowing already
# stops every Skill dispatch, so "wrote nothing" is correct for the malformed
# and the well-formed alike and only rc=0 is ever proved. Here review_tests is
# the ACTIVE allowlisted step, so a Skill dispatch does mark. isMetaOpDispatch
# fails OPEN on the null skillNameOf returns for an unreadable name: a hook that
# failed closed would end the lookahead on any host that renames the field, and
# C4 would nag mid-dispatch.
run_B24() {
    local label raw want sid tmp tn status origin problems=""
    while IFS='|' read -r label raw want; do
        label="$(trim "$label")"; raw="$(trim "$raw")"; want="$(trim "$want")"
        case "$label" in ''|'#'*) continue ;; esac
        sid="b24-$label"
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        _skill_setup_review_tests "$tmp" "$tn" "$sid"
        if [ "$(step_status "$tmp" "$sid" review_tests)" = "in_progress" ]; then
            problems="$problems [$label: fixture already had review_tests in_progress — nothing is under test]"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi
        run_automark_raw "$tn" "$(printf '%s' "$raw" | sed "s/@SID@/$sid/g")"
        status="$(step_status "$tmp" "$sid" review_tests)"
        origin="$(_b22_origin "$tn" "$sid" review_tests)"
        [ "$AM_RC" -eq 0 ] || problems="$problems [$label: hook exited $AM_RC, want 0]"
        if [ "$want" = "marked" ]; then
            [ "$status" = "in_progress" ] ||
                problems="$problems [$label: review_tests is '$status' — an unreadable skill name fails CLOSED, so the dispatch under way is no longer recorded]"
            [ "$origin" = "postuse-in-flight/true" ] ||
                problems="$problems [$label: origin/lookahead-only is '$origin', want 'postuse-in-flight/true' — the mark is not attributable to the lookahead]"
        else
            [ "$status" != "in_progress" ] ||
                problems="$problems [$label: the meta-op dispatch claimed review_tests (#2279)]"
        fi
        rm -rf "$tmp" 2>/dev/null || true
    done <<'EOF'
# label          | raw stdin                                                                                               | review_tests after
skill-absent     | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":{"description":"x"}} | marked
skill-number     | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":{"skill":42}} | marked
skill-empty      | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":{"skill":""}} | marked
skill-object     | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":{"skill":{"n":"x"}}} | marked
tool-input-null  | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":null} | marked
tool-input-array | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":["resume-session"]} | marked
meta-op          | {"tool_name":"Skill","session_id":"@SID@","transcript_path":"","tool_input":{"skill":"resume-session"}} | unchanged
EOF
    if [ -z "$problems" ]; then
        pass "B24: at an ACTIVE allowlisted step, a Skill payload whose name the hook cannot resolve still takes the ordinary marking path under the lookahead origin, while the one name it CAN resolve as the meta-op is the only one left out"
    else
        fail "B24: malformed Skill payloads are not handled fail-open at an active step;$problems"
    fi
}

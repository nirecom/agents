# e-lookahead-guard.sh — C-a..C-g: the lookahead must not make a never-started
# session look started to the C4 guard, and the pre-workflow-init exemption must
# not swallow the mechanism-failure lane (#2213, the #2279 companion).
# Tests: hooks/stop-premature-stop-guard.js, hooks/workflow-state/lifecycle.js, hooks/postuse-step-in-flight-mark.js
# Tags: stop-hook, c4, step-in-flight, wi-10-lookahead, pre-workflow-init, regression-2213, regression-2279, scope:issue-specific, pwsh-not-required, TL2

# c-guard.sh measures the exemption for a session already IN a workflow. This
# is the opposite population: a session that never ran /workflow-init, whose
# only recorded event is the lookahead's own `research` in_progress. The
# pre-workflow-init exemption is what keeps C4 quiet there, and the lookahead
# silently disqualifies the session from it. Separate file per Pattern A.
_started() { pred_eval "$1" "L.isWorkflowStarted('$2')"; }

# _seed_corrupt <tmp> <sid> — a state file that exists but cannot be parsed, so
# readState returns null and detectStalledSteps classifies it `state-corrupt`
# (the M4 shape of tests/feature-1997-mechanism-failure/m-detect.sh). No event
# is ever recorded, so the session is pre-workflow-init by construction.
_seed_corrupt() { printf '{ this is not json' > "$1/$2.json"; }

# _stalls <tn> <sid> — "step:kind" for every detectStalledSteps finding, joined.
# The mechanism-failure lane's own input: a case must prove the lane HAS
# something to report before it can assert what the guard did with it.
_stalls() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 20 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/mechanism-failure.js').detectStalledSteps('$2') || [];
process.stdout.write(f.map((x) => x.step + ':' + x.kind).join(','));" 2>/dev/null
}

# C-a: the pre-workflow-init baseline — no state file at all. The anchor the
# cases below are measured against; if this ever blocks, C-c/C-d's failures
# become indistinguishable from a broken exemption ordering.
run_Ca() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _row_env "$tmp"
    run_c4 "$tn" ca
    [ "$C4_RC" = "0" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 0 — a session with no state file has no workflow to be premature about]"
    [ "$(_started "$tn" ca)" = "false" ] ||
        problems="$problems [isWorkflowStarted said true for a session with no state file]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-a: a session with no state file is not started and C4 is silent (the pre-workflow-init exemption)"
    else
        fail "C-a: the pre-workflow-init baseline is broken;$problems"
    fi
}

# C-b: the same exemption one step further in — a state file exists but every
# step is pending. Written directly, so no event stream backs it: the "file
# exists" fact alone must not count as having started.
run_Cb() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _seed_row "$tmp" cb "" research pending
    _row_env "$tmp"
    run_c4 "$tn" cb
    [ "$C4_RC" = "0" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 0 — an all-pending state file is still a session that never started]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-b: an all-pending state file does not start a workflow — C4 stays silent"
    else
        fail "C-b: the mere existence of a state file is being read as progress;$problems"
    fi
}

# C-c: #2213 proper. The lookahead marked `research`, four hours passed, and
# the step-in-flight exemption expired with it. The session still never started
# a workflow, so pre-workflow-init must carry it — but the lookahead's own mark
# made isWorkflowStarted true, so the user is nudged about a workflow they never
# began. The TTL is what separates this from C1's `fresh` rows: it removes the
# exemption that would otherwise hide the wrong answer.
run_Cc() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _row_env "$tmp"
    run_automark "$tn" cc Agent
    [ "$(step_status "$tmp" cc research)" = "in_progress" ] ||
        problems="$problems [fixture: the lookahead did not mark research, so nothing is under test]"
    backdate_step "$tmp" cc research $((TTL_MS + 60000))
    run_c4 "$tn" cc
    [ "$C4_RC" = "0" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 0 — the lookahead mark is the ONLY event in this session's stream, so it never started a workflow]"
    [ "$(_started "$tn" cc)" = "false" ] ||
        problems="$problems [isWorkflowStarted said true, on the strength of a lookahead mark the session never asked for]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-c: an expired lookahead-only mark leaves the session un-started — C4 does not nudge about a workflow that was never begun (#2213)"
    else
        fail "C-c: the WI-10 lookahead promotes a never-started session to 'started';$problems"
    fi
}

# C-d: the #2279 shape of the same fault. /resume-session is dispatched through
# the Skill tool on a fresh session; the readers that decide whether that
# session may ADOPT another's state ask isWorkflowStarted, and the dispatch
# answering "yes" is precisely what makes `--from` a no-op.
run_Cd() {
    local tmp tn problems="" digest
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _row_env "$tmp"
    run_automark "$tn" cd Skill "" resume-session
    digest="$(state_digest "$tmp" cd)"
    [ "$(_started "$tn" cd)" = "false" ] ||
        problems="$problems [isWorkflowStarted said true after a Skill dispatch of resume-session; state is '$digest']"
    run_c4 "$tn" cd
    [ "$C4_RC" = "0" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 0]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-d: dispatching /resume-session through the Skill tool leaves a fresh session un-started (the #2279 precondition for adoption)"
    else
        fail "C-d: the resume-session dispatch itself starts the workflow it was invoked to restore;$problems"
    fi
}

# C-e: the non-regression counterweight. A session that GENUINELY started must
# still be nudgeable with research pending; without it, "make isWorkflowStarted
# return false" is a passing fix for C-c and C-d and a total loss of the guard.
# Seeded via _seed_row, the same direct-write shape C1's passing rows use — C3's
# markStep-built fixture is silent today for an unrelated reason (see report).
run_Ce() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _seed_row "$tmp" ce "workflow_init clarify_intent" research pending
    _row_env "$tmp"
    run_c4 "$tn" ce
    [ "$C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — a started session with research pending and nothing in flight must still be nudged]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-e: a started session with nothing in flight is still nudged by C4 (the exemption did not swallow the guard)"
    else
        fail "C-e: narrowing 'started' has cost the guard its real cases;$problems"
    fi
}

# FAIL-BEFORE-FIX (#2213): C-f/C-g assert the CORRECT post-fix contract and are
# EXPECTED TO FAIL today — the guard exits 0 at the session-level
# `pre-workflow-init` row before mechanismStalls() runs. C-a..C-e measure the
# premature-stop lane (correctly exempt); these measure the mechanism-failure
# lane (not exempt unless the finding's own step is lookahead-only — C-c).

# C-f: a corrupt state file in a session that never settled a step. Its finding
# is reported under the `(state)` pseudo-step, which no lookahead can have
# marked, so "never started" cannot excuse it — the state the whole mechanism
# runs on is unreadable, and silence here is the #1997 silence returning.
run_Cf() {
    local tmp tn problems="" kinds
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _seed_corrupt "$tmp" cf
    _row_env "$tmp"
    kinds="$(_stalls "$tn" cf)"
    case "$kinds" in
        *"(state):state-corrupt"*) : ;;
        *) problems="$problems [fixture: detectStalledSteps reports '${kinds:-<empty>}', not (state):state-corrupt — nothing is under test]" ;;
    esac
    [ "$(_started "$tn" cf)" = "false" ] ||
        problems="$problems [fixture: isWorkflowStarted said true for an unreadable state file, so this is no longer the pre-workflow-init population]"
    run_c4 "$tn" cf
    [ "$C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — a corrupt state file is a mechanism failure whatever the session's workflow status is]"
    case "$C4_OUT" in
        *"mechanism-failure"*) : ;;
        *) problems="$problems [C4 emitted '${C4_OUT:-<nothing>}' — no mechanism-failure block]" ;;
    esac
    case "$C4_OUT" in
        *"state-corrupt"*) : ;;
        *) problems="$problems [the block does not name the state-corrupt kind: '${C4_OUT:-<nothing>}']" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-f: a corrupt state file is still surfaced as a C4 mechanism failure in a session that never started the workflow (#2213)"
    else
        fail "C-f: the pre-workflow-init exemption swallows the mechanism-failure lane;$problems"
    fi
}

# C-g: the same fault with a real step. A genuine dispatch-style mark (default
# `mark-step` origin, NOT the lookahead origin) on write_tests, expired past the
# TTL, in a session where no step has settled — isWorkflowStarted is false for
# the ordinary reason, not a lookahead artifact. C-c is the mirror image (same
# lane, same TTL, lookahead-only) where silence is correct; neither case alone
# specifies the fix.
run_Cg() {
    local tmp tn problems="" kinds status
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_step "$tn" cg write_tests in_progress
    backdate_step "$tmp" cg write_tests $((TTL_MS + 60000))
    _row_env "$tmp"
    status="$(step_status "$tmp" cg write_tests)"
    [ "$status" = "in_progress" ] ||
        problems="$problems [fixture: write_tests is '$status', not in_progress — nothing is under test]"
    [ "$(_started "$tn" cg)" = "false" ] ||
        problems="$problems [fixture: isWorkflowStarted said true, but no step has settled — this is not the pre-workflow-init population]"
    [ "$(pred_eval "$tn" "L.isLookaheadOnlyInFlight('cg', 'write_tests')")" = "false" ] ||
        problems="$problems [fixture: the mark reads as lookahead-only, so this case would duplicate C-c instead of opposing it]"
    kinds="$(_stalls "$tn" cg)"
    case "$kinds" in
        *"write_tests:in-flight-expired"*) : ;;
        *) problems="$problems [fixture: detectStalledSteps reports '${kinds:-<empty>}', not write_tests:in-flight-expired]" ;;
    esac
    run_c4 "$tn" cg
    [ "$C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — a genuinely claimed step that outlived the TTL is a stalled mechanism, and no lookahead artifact explains it away]"
    case "$C4_OUT" in
        *"write_tests"*) : ;;
        *) problems="$problems [the block does not name write_tests: '${C4_OUT:-<nothing>}']" ;;
    esac
    case "$C4_OUT" in
        *"in-flight-expired"*) : ;;
        *) problems="$problems [the block does not name the in-flight-expired kind: '${C4_OUT:-<nothing>}']" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-g: a genuine (non-lookahead) in_progress mark that outlived the TTL is still surfaced as a C4 mechanism failure before any step has settled (#2213)"
    else
        fail "C-g: a real stalled step is silenced merely because no step has settled yet;$problems"
    fi
}

# C-h: the two findings TOGETHER, which is what the filter's shape is actually
# about. C-c measures a lookahead-only finding alone (correctly silenced) and C-g
# a genuine one alone (correctly surfaced); a guard that filtered by SESSION —
# "any exempt finding present => suppress every finding" — passes both and loses
# the genuine one the moment the two coexist. The filter at the require.main
# block is per-FINDING for exactly this population, so only the combined fixture
# can hold it to that. The stall list below is asserted BEFORE the verdict: two
# distinct pre-filter findings are what makes the assertion non-vacuous.
run_Ch() {
    local tmp tn problems="" kinds
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _row_env "$tmp"
    # The exempt half: the lookahead's own `research` mark (C-c's fixture).
    run_automark "$tn" ch Agent
    [ "$(step_status "$tmp" ch research)" = "in_progress" ] ||
        problems="$problems [fixture: the lookahead did not mark research, so the exempt half of the pair is missing]"
    # The genuine half: a real claim on a DIFFERENT step (C-g's fixture).
    seed_step "$tn" ch write_tests in_progress
    [ "$(step_status "$tmp" ch write_tests)" = "in_progress" ] ||
        problems="$problems [fixture: write_tests is '$(step_status "$tmp" ch write_tests)', not in_progress]"
    backdate_step "$tmp" ch research $((TTL_MS + 60000))
    backdate_step "$tmp" ch write_tests $((TTL_MS + 60000))

    [ "$(_started "$tn" ch)" = "false" ] ||
        problems="$problems [fixture: isWorkflowStarted said true, so this is not the pre-workflow-init population the per-finding filter applies to]"
    [ "$(pred_eval "$tn" "L.isLookaheadOnlyInFlight('ch', 'research')")" = "true" ] ||
        problems="$problems [fixture: the research mark does not read as lookahead-only, so nothing here is exempt]"
    [ "$(pred_eval "$tn" "L.isLookaheadOnlyInFlight('ch', 'write_tests')")" = "false" ] ||
        problems="$problems [fixture: the write_tests mark reads as lookahead-only, so both findings are exempt and the case duplicates C-c]"

    kinds="$(_stalls "$tn" ch)"
    case "$kinds" in
        *"research:in-flight-expired"*) : ;;
        *) problems="$problems [fixture: detectStalledSteps reports '${kinds:-<empty>}' — the exempt finding is not in the pre-filter list, so its exclusion proves nothing]" ;;
    esac
    case "$kinds" in
        *"write_tests:in-flight-expired"*) : ;;
        *) problems="$problems [fixture: detectStalledSteps reports '${kinds:-<empty>}' — the genuine finding is not in the pre-filter list]" ;;
    esac

    run_c4 "$tn" ch
    [ "$C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — the genuine stall on write_tests must still block, whatever the lookahead did to research]"
    case "$C4_OUT" in
        *"write_tests"*) : ;;
        *) problems="$problems [the block does not name write_tests: '${C4_OUT:-<nothing>}' — the exempt sibling swallowed the genuine finding, so the filter is judging the session rather than each finding]" ;;
    esac
    case "$C4_OUT" in
        *"research"*) problems="$problems [the block names research: '$C4_OUT' — the lookahead-only finding was reported anyway, so the per-finding exemption is not applied]" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C-h: with an exempt lookahead-only finding AND a genuine stall on another step in the same pre-workflow-init session, C4 blocks on the genuine one alone — the mechanism-failure filter is per-finding, not per-session (#2213)"
    else
        fail "C-h: the pre-workflow-init exemption is applied to the whole session instead of the finding that earns it;$problems"
    fi
}

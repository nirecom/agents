#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/final-report-step.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-mark/mark-step-handler.js, hooks/lib/sentinel-patterns.js, hooks/workflow-gate.js
# Tags: workflow-state, event-stream, final-report, valid-steps, terminal-steps, sentinel-parsing, scope:issue-specific, pwsh-not-required, TL2
#
# #1733 adds `final_report` to VALID_STEPS so the event stream has a terminal boundary
# for computeIntervals. Two failure modes come with it. (1) VALID_STEPS is also the list
# the commit gate iterates, so an unguarded addition would demand a step nobody can
# complete before committing — hence the NON_GATE_STEPS / TERMINAL_STEPS coverage here.
# (2) The MARK_STEP regex is `([a-z_]+)_(complete|skipped|pending|in_progress)`, whose
# greedy first group only yields step=final_report by BACKTRACKING; the neighbouring
# `pre_final_report_gate` shares that prefix, so both are parsed here explicitly.
#
# TL3 gap (what this test does NOT catch):
# - hook REGISTRATION: F11 spawns hooks/workflow-gate.js as its own process and feeds it
#   the PreToolUse JSON payload, so the gate's real verdict is observed — but the run is
#   still driven by this script, not by Claude Code reading settings.json. A gate that
#   stops being wired as a PreToolUse hook still passes here.
# - a real `git commit` actually being refused by the harness (the gate only prints a
#   verdict; the enforcement of that verdict belongs to Claude Code).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="fr"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== F1: final_report is the last entry of VALID_STEPS =="
if run_case "F1/valid-steps-tail"; then
    next_sid
    nodejs "$SID" '
const S = require("./hooks/workflow-state/state-io");
const v = S.VALID_STEPS;
console.log("present=" + v.includes("final_report") +
            " is_last=" + (v[v.length - 1] === "final_report") +
            " after=" + v[v.length - 2] +
            " unique=" + (new Set(v).size === v.length));
'
    assert_eq "F1/valid-steps-tail" \
        "present=true is_last=true after=pre_final_report_gate unique=true" "$NODE_OUT"
fi

echo "== F2: TERMINAL_STEPS is exported as the SSOT and names final_report =="
if run_case "F2/terminal-steps-ssot"; then
    next_sid
    nodejs "$SID" '
const S = require("./hooks/workflow-state/state-io");
const t = S.TERMINAL_STEPS;
console.log("is_array=" + Array.isArray(t) +
            " has_final_report=" + (Array.isArray(t) && t.includes("final_report")) +
            " all_valid=" + (Array.isArray(t) && t.every((s) => S.VALID_STEPS.includes(s))));
'
    assert_eq "F2/terminal-steps-ssot" "is_array=true has_final_report=true all_valid=true" "$NODE_OUT"
fi

echo "== F3: the MARK_STEP regex backtracks to step=final_report, status=complete =="
next_sid
nodejs "$SID" '
const { MARKER_RE_DQ, MARKER_RE_SQ } = require("./hooks/lib/sentinel-patterns");
const parse = (re, cmd) => { const m = cmd.match(re); return m ? m[1] + "/" + m[2] : "NOMATCH"; };
console.log([
  "dq=" + parse(MARKER_RE_DQ, "echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\""),
  "sq=" + parse(MARKER_RE_SQ, "echo \x27<<WORKFLOW_MARK_STEP_final_report_complete>>\x27"),
  "gate=" + parse(MARKER_RE_DQ, "echo \"<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>\""),
  "pending=" + parse(MARKER_RE_DQ, "echo \"<<WORKFLOW_MARK_STEP_final_report_pending>>\""),
].join(" "));
'
# The greedy [a-z_]+ must not swallow "_complete" — and the shared prefix must not make
# pre_final_report_gate parse as final_report.
assert_eq "F3/marker-regex-backtracking" \
    "dq=final_report/complete sq=final_report/complete gate=pre_final_report_gate/complete pending=final_report/pending" \
    "$NODE_OUT"

echo "== F4: marking final_report complete appends one observed step_status event =="
if run_case "F4/mark-appends-event"; then
    next_sid
    nodejs "$SID" "$PRE"'
const mh = require("./hooks/workflow-mark/mark-step-handler");
S.markStep(sid, "workflow_init", "complete");
const before = rd().events.length;
const msgs = [];
mh.handle({
  cmd: "echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\"",
  sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: () => {}, repoCwd: process.cwd(),
});
const ev = rd().events.filter((e) => e.kind === "step_status" && e.step === "final_report");
console.log("appended=" + (rd().events.length - before) +
            " status=" + (ev[0] && ev[0].status) +
            " provenance=" + (ev[0] && ev[0].provenance) +
            " rejected=" + msgs.some((m) => /NOT recorded/.test(m)));
'
    assert_eq "F4/mark-appends-event" \
        "appended=1 status=complete provenance=observed rejected=false" "$NODE_OUT"
fi

echo "== F5: final_report is a non-gate step, so it cannot block a commit =="
if run_case "F5/non-gate-steps-exempt"; then
    GATE_SRC="$AGENTS_DIR/hooks/workflow-gate.js"
    NG_LINE="$(grep -n 'NON_GATE_STEPS = ' "$GATE_SRC" | head -1)"
    HAS_FR="no"; case "$NG_LINE" in *'"final_report"'*) HAS_FR="yes";; esac
    HAS_RESEARCH="no"; case "$NG_LINE" in *'"research"'*) HAS_RESEARCH="yes";; esac
    # Structural check on purpose: VALID_STEPS is what the gate loop iterates, so adding
    # a step there without exempting it here turns every commit into a hard block.
    assert_eq "F5/non-gate-steps-exempt" "final_report=yes research=yes" \
        "final_report=$HAS_FR research=$HAS_RESEARCH"
fi

echo "== F6: final_report closes the stream — nothing is appended for it by default =="
if run_case "F6/not-auto-completed"; then
    next_sid
    nodejs "$SID" "$PRE"'
for (const s of ["workflow_init", "clarify_intent", "run_tests", "cleanup"]) S.markStep(sid, s, "complete");
const st = S.readState(sid);
console.log("projected=" + st.steps.final_report.status +
            " events=" + rd().events.filter((e) => e.step === "final_report").length);
'
    # A terminal boundary that auto-appears would make every interval report claim the
    # session is finished.
    assert_eq "F6/not-auto-completed" "projected=pending events=0" "$NODE_OUT"
fi

echo "== F7: an unknown step name is still rejected (the addition did not loosen validation) =="
if run_case "F7/unknown-step-rejected"; then
    next_sid
    nodejs "$SID" "$PRE"'
let err = "none";
try { S.markStep(sid, "final_reports", "complete"); } catch (e) { err = "threw"; }
const mh = require("./hooks/workflow-mark/mark-step-handler");
const msgs = [];
mh.handle({
  cmd: "echo \"<<WORKFLOW_MARK_STEP_final_reporting_complete>>\"",
  sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: () => {}, repoCwd: process.cwd(),
});
const exists = fs.existsSync(sp());
const bogus = exists ? rd().events.filter((e) => /final_report/.test(String(e.step))).length : 0;
console.log("markStep=" + err + " bogus_events=" + bogus + " warned=" + (msgs.length > 0));
'
    assert_eq "F7/unknown-step-rejected" "markStep=threw bogus_events=0 warned=true" "$NODE_OUT"
fi

# run_next_step <sid> [args...] — spawns the REAL CLI as its own process.
# Everything above reads constants out of modules; that cannot see the dispatcher's own
# wiring (STEP_TO_SKILL / STEP_DESC completeness checks, the advisory walk, the --list
# renderer). A step added to VALID_STEPS with no dispatcher entry aborts this binary at
# startup, and no module-level assertion notices.
run_next_step() {
    local sid="$1"; shift
    NS_RC=0
    NS_OUT="$(cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node "$AGENTS_DIR/bin/workflow/next-step" \
        --session "$sid" "$@" 2>&1)" || NS_RC=$?
}

# Drives a session to the state the dispatcher treats as finished: every gate step
# complete, every skippable step skipped, final_report untouched.
SEED_DONE_JS='
S.updateTopLevel(sid, (st) => { st.workflow_type = "wf-code"; st.closes_issues = [1733]; });
["clarify_intent", "research", "outline", "detail", "write_tests", "review_tests",
 "review_security", "cleanup"].forEach((s) => S.markStep(sid, s, "skipped", { skip_reason: "fixture" }));
["workflow_init", "branching_complete", "run_tests", "docs", "user_verification",
 "pre_final_report_gate"].forEach((s) => S.markStep(sid, s, "complete"));
console.log("SEEDED " + S.readState(sid).steps.final_report.status);
'

echo "== F8: the real next-step CLI still reports done — final_report is not a new blocking gate =="
if run_case "F8/cli-done-not-blocked"; then
    next_sid
    SID_F8="$SID"
    nodejs "$SID_F8" "$PRE$SEED_DONE_JS"
    assert_eq "F8/seed" "SEEDED pending" "$NODE_OUT"

    run_next_step "$SID_F8"
    # The whole point of a TERMINAL step: it exists for the interval calculation, and the
    # advisory walk must skip over it. If it were walked like any other step, every
    # session would end by being told to run a skill that does not exist, forever.
    NS_ACTION="$(printf '%s' "$NS_OUT" | sed -n 's/^ACTION=//p' | head -1)"
    NS_REASON="$(printf '%s' "$NS_OUT" | sed -n "s/^REASON=//p" | head -1 | tr -d "'")"
    NS_SKILL="$(printf '%s' "$NS_OUT" | sed -n 's/^NEXT_SKILL=//p' | head -1)"
    assert_eq "F8/cli-exit-code" "0" "$NS_RC"
    assert_eq "F8/cli-action" "done" "$NS_ACTION"
    assert_eq "F8/cli-reason" "workflow-complete" "$NS_REASON"
    assert_eq "F8/cli-no-skill-advised" "" "$NS_SKILL"
    if printf '%s' "$NS_OUT" | grep -q "final_report"; then
        fail "F8/cli-does-not-advise-final-report" "$NS_OUT"
    else
        pass "F8/cli-does-not-advise-final-report"
    fi
fi

echo "== F9: --list renders every VALID_STEPS row, with final_report as the terminal one =="
if run_case "F9/cli-list-terminal-row"; then
    next_sid
    SID_F9="$SID"
    nodejs "$SID_F9" "$PRE$SEED_DONE_JS"
    assert_eq "F9/seed" "SEEDED pending" "$NODE_OUT"

    run_next_step "$SID_F9" --list
    assert_eq "F9/list-exit-code" "0" "$NS_RC"

    # Row count is asserted against the SSOT rather than a literal: hardcoding 15 here
    # would have to be edited again by the next step addition, and a stale literal fails
    # for a reason that has nothing to do with what this case is about.
    nodejs "$SID_F9" 'console.log(require("./hooks/workflow-state/state-io").VALID_STEPS.length);'
    NS_ROWS="$(printf '%s\n' "$NS_OUT" | grep -cE '^\[[x*[:space:]!-]\] +[0-9]+  ')"
    assert_eq "F9/list-row-count-matches-VALID_STEPS" "$NODE_OUT" "$NS_ROWS"

    NS_LAST="$(printf '%s\n' "$NS_OUT" | grep -E '^\[[x*[:space:]!-]\] +[0-9]+  ' | tail -1)"
    if printf '%s' "$NS_LAST" | grep -qE '^\[[ *]\] +[0-9]+  final_report  .+'; then
        pass "F9/final-report-is-last-row"
    else
        fail "F9/final-report-is-last-row" "last row: $NS_LAST"
    fi
    # A description is mandatory: the renderer prints STEP_DESC[step] unconditionally, so
    # a missing entry shows up as the string "undefined" in the user-visible plan.
    if printf '%s' "$NS_OUT" | grep -q "undefined"; then
        fail "F9/no-missing-step-desc" "$NS_OUT"
    else
        pass "F9/no-missing-step-desc"
    fi
fi

echo "== F10: marking final_report complete does not change the CLI verdict =="
if run_case "F10/cli-after-terminal-mark"; then
    next_sid
    SID_F10="$SID"
    nodejs "$SID_F10" "$PRE$SEED_DONE_JS"
    assert_eq "F10/seed" "SEEDED pending" "$NODE_OUT"
    nodejs "$SID_F10" "$PRE"'S.markStep(sid, "final_report", "complete"); console.log("MARKED");'
    assert_eq "F10/mark" "MARKED" "$NODE_OUT"

    run_next_step "$SID_F10"
    NS_ACTION="$(printf '%s' "$NS_OUT" | sed -n 's/^ACTION=//p' | head -1)"
    NS_REASON="$(printf '%s' "$NS_OUT" | sed -n "s/^REASON=//p" | head -1 | tr -d "'")"
    assert_eq "F10/cli-action-unchanged" "done" "$NS_ACTION"
    assert_eq "F10/cli-reason-unchanged" "workflow-complete" "$NS_REASON"

    run_next_step "$SID_F10" --list
    NS_LAST="$(printf '%s\n' "$NS_OUT" | grep -E '^\[[x*[:space:]!-]\] +[0-9]+  ' | tail -1)"
    if printf '%s' "$NS_LAST" | grep -qE '^\[x\] +[0-9]+  final_report  '; then
        pass "F10/list-shows-terminal-complete"
    else
        fail "F10/list-shows-terminal-complete" "last row: $NS_LAST"
    fi
fi

# run_gate <payload-file> — spawns hooks/workflow-gate.js as the REAL PreToolUse hook
# process: JSON on stdin, always exit 0, verdict on stdout as
# {"decision":"approve"} / {"decision":"block","reason":...}.
#
# F5 above reads the NON_GATE_STEPS constant out of the source text. That is a static
# check: it cannot fail when the constant is correct but the loop that consumes it is
# not, and it cannot distinguish "final_report is exempt" from "the gate approves
# everything". F11 below closes that by driving both verdicts through the real binary.
run_gate() { # <payload-file>
    GATE_RC=0
    GATE_OUT="$(cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        ENFORCE_WORKTREE=off \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node "$AGENTS_DIR/hooks/workflow-gate.js" \
        < "$1" 2>/dev/null)" || GATE_RC=$?
}

# gate_payload <sid> <repo-json-path> <out-file> — the PreToolUse payload for a commit.
# `git -C <repo>` is used so resolveRepoDir Tier 1 pins the fixture repo: without it
# Tier 4 falls back to process.cwd(), i.e. the developer's real agents checkout, whose
# staged WIP would decide the verdict instead of the fixture.
gate_payload() { # <sid> <repo-json-path> <out-file>
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s commit -m fixture","cwd":"%s"}}' \
        "$1" "$2" "$2" > "$3"
}

echo "== F11: the REAL workflow-gate process approves with final_report pending, and still blocks a genuinely pending step =="
if run_case "F11/gate-live-verdicts"; then
    # NEW (codex review-tests HIGH finding 5). Both verdicts of the classifier are covered
    # (test-design.md "Classifier / guard cases"): the exemption is only meaningful if the
    # gate can still say no.
    GATE_REPO="$TMPROOT/gate-repo"
    if ! mk_git_repo "$GATE_REPO" "feature/1733-gate-fixture"; then
        fail "F11/fixture-repo" "mk_git_repo failed for $GATE_REPO"
    else
        # A NON-docs staged file: a docs-only staging set short-circuits every step except
        # user_verification, which would make the negative control approve for the wrong
        # reason. Kept tiny so the #1701 file-size gate has nothing to say about it.
        mkdir -p "$GATE_REPO/src"
        printf 'module.exports = 1;\n' > "$GATE_REPO/src/app.js"
        git -C "$GATE_REPO" add src/app.js >/dev/null 2>&1
        GATE_REPO_JSON="$(json_path "$GATE_REPO")"
        GATE_PAYLOAD="$TMPROOT/gate-payload.json"

        # (a) POSITIVE CONTROL — every enforceable step satisfied, final_report still
        #     pending. NON_GATE_STEPS must exempt it, so the gate approves.
        next_sid
        SID_F11A="$SID"
        nodejs "$SID_F11A" "$PRE$SEED_DONE_JS"
        assert_eq "F11a/seed" "SEEDED pending" "$NODE_OUT"
        gate_payload "$SID_F11A" "$GATE_REPO_JSON" "$GATE_PAYLOAD"
        run_gate "$GATE_PAYLOAD"
        assert_eq "F11a/gate-exit-code" "0" "$GATE_RC"
        if printf '%s' "$GATE_OUT" | grep -q '"decision":"approve"'; then
            pass "F11a/final-report-pending-still-approves"
        else
            fail "F11a/final-report-pending-still-approves" "$GATE_OUT"
        fi
        # A block naming final_report would mean the exemption regressed; a block naming
        # anything else would mean this control is not isolating what it claims to.
        if printf '%s' "$GATE_OUT" | grep -q "final_report"; then
            fail "F11a/gate-never-demands-final-report" "$GATE_OUT"
        else
            pass "F11a/gate-never-demands-final-report"
        fi

        # (b) NEGATIVE CONTROL — identical state except run_tests is pending. run_tests is
        #     sentinel-only (no evidence predicate in evidence-resolver.js), so nothing can
        #     resolve it behind the test's back. The gate must block and name it.
        next_sid
        SID_F11B="$SID"
        nodejs "$SID_F11B" "$PRE$SEED_DONE_JS"
        assert_eq "F11b/seed" "SEEDED pending" "$NODE_OUT"
        nodejs "$SID_F11B" "$PRE"'S.markStep(sid, "run_tests", "pending");
console.log("DEMOTED " + S.readState(sid).steps.run_tests.status);'
        assert_eq "F11b/demote" "DEMOTED pending" "$NODE_OUT"
        gate_payload "$SID_F11B" "$GATE_REPO_JSON" "$GATE_PAYLOAD"
        run_gate "$GATE_PAYLOAD"
        assert_eq "F11b/gate-exit-code" "0" "$GATE_RC"
        if printf '%s' "$GATE_OUT" | grep -q '"decision":"block"'; then
            pass "F11b/pending-enforceable-step-blocks"
        else
            fail "F11b/pending-enforceable-step-blocks" "$GATE_OUT"
        fi
        if printf '%s' "$GATE_OUT" | grep -q "run_tests"; then
            pass "F11b/block-reason-names-run-tests"
        else
            fail "F11b/block-reason-names-run-tests" "$GATE_OUT"
        fi
    fi
fi
finish "final-report-step"

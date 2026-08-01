#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/reset-from.sh
# Tests: hooks/workflow-mark/reset-handler.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-state/state-io/events.js
# Tags: workflow-state, event-stream, reset-from, workflow-init, append-only, regression, scope:issue-specific, pwsh-not-required, TL2
#
# RESET_FROM used to rebuild the state from createInitialState and write the whole thing
# back, which (a) destroyed the audit trail and (b) silently dropped closes_issues /
# workflow_type / session_model / last_pushed_sha — a pre-existing bug that append-only
# fixes structurally. Both halves are pinned here: the stream may only GROW, and the
# top-level settings must survive. The same batch shape is used by the workflow_init
# downstream reset, so that route is covered too (CPR-5 symmetry).
#
# TL3 gap (what this test does NOT catch):
# - the real PreToolUse Bash hook that parses the RESET_FROM sentinel out of a command
#   line; handlers are invoked as modules here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="reset"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Seeds a realistic mid-session state: gated approvals, several complete steps with
# annotations, and every top-level setting RESET_FROM used to lose.
SEED_JS="$PRE$APPROVE_GATED_JS"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
S.markStep(sid, "research", "skipped", { skip_reason: "nothing to survey" });
S.markStep(sid, "outline", "complete");
S.markStep(sid, "detail", "complete");
S.markStep(sid, "review_tests", "complete", { token: "tok-1", wsid: "wsid-1" });
S.recordSessionModel(sid, { id: "claude-opus-5", source: "transcript" });
S.setLastPushedSha(sid, "0".repeat(40));
{ const st = S.readState(sid); st.closes_issues = [1733]; st.workflow_type = "wf-code"; S.writeState(sid, st); }
'

# Block-scoped on purpose: R8 concatenates this snippet twice into one script, so a
# top-level `const` would be a SyntaxError rather than a second reset.
RESET_JS='{
  const rh = require("./hooks/workflow-mark/reset-handler");
  rh.handle({
    cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: rework the plan>>\"",
    sessionId: sid, pushMessage: () => {}, signalFatal: () => {}, repoCwd: process.cwd(),
  });
}
'

echo "== R1: RESET_FROM only appends — no prior event is removed or altered =="
if run_case "R1/append-only"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
const before = rd().events;
const beforeJson = JSON.stringify(before);
'"$RESET_JS"'
const after = rd().events;
console.log("grew=" + (after.length > before.length) +
            " prefix_identical=" + (JSON.stringify(after.slice(0, before.length)) === beforeJson) +
            " seq_contiguous=" + after.every((e, i) => e.seq === i + 1));
'
    assert_eq "R1/append-only" "grew=true prefix_identical=true seq_contiguous=true" "$NODE_OUT"
fi

echo "== R2: a reset event anchors the audit trail =="
if run_case "R2/reset-anchor-event"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const ev = rd().events.filter((e) => e.kind === "reset");
const r = ev[0] || {};
console.log("n=" + ev.length + " from_step=" + r.from_step + " reason=" + r.reason +
            " provenance=" + r.provenance + " origin=" + r.origin);
'
    assert_eq "R2/reset-anchor-event" \
        "n=1 from_step=detail reason=rework the plan provenance=declared origin=reset-sentinel" "$NODE_OUT"
fi

echo "== R3: steps before from_step are declared complete; from_step onward are pending =="
if run_case "R3/status-partition"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const st = S.readState(sid);
const i = S.VALID_STEPS.indexOf("detail");
const badF = S.VALID_STEPS.slice(0, i).filter((s) => st.steps[s].status !== "complete");
const badB = S.VALID_STEPS.slice(i).filter((s) => st.steps[s].status !== "pending");
console.log("before_not_complete=" + (badF.join(",") || "0") +
            " from_onward_not_pending=" + (badB.join(",") || "0"));
'
    assert_eq "R3/status-partition" "before_not_complete=0 from_onward_not_pending=0" "$NODE_OUT"
fi

echo "== R4: annotations from from_step onward are explicitly cleared =="
if run_case "R4/annotations-cleared-forward"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const st = S.readState(sid);
const cleared = rd().events.filter((e) => e.kind === "step_annotations_cleared").map((e) => e.step);
const i = S.VALID_STEPS.indexOf("detail");
const expected = S.VALID_STEPS.slice(i);
const missing = expected.filter((s) => !cleared.includes(s));
console.log("missing_clear=" + (missing.join(",") || "0") +
            " review_tests_token=" + ("token" in st.steps.review_tests) +
            " research_skip_reason=" + st.steps.research.skip_reason);
'
    # research is BEFORE detail, so its annotation must survive; review_tests is after.
    assert_eq "R4/annotations-cleared-forward" \
        "missing_clear=0 review_tests_token=false research_skip_reason=nothing to survey" "$NODE_OUT"
fi

echo "== R5: top-level settings survive RESET_FROM (the reset-drops-toplevel regression) =="
if run_case "R5/toplevel-survives"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const st = S.readState(sid);
console.log([
  "closes_issues=" + JSON.stringify(st.closes_issues),
  "workflow_type=" + st.workflow_type,
  "last_pushed_sha=" + (st.last_pushed_sha ? "kept" : "LOST"),
  "session_model=" + (st.session_model && st.session_model.id),
  "created_at_stable=" + (st.created_at === JSON.parse(raw()).created_at),
].join(" "));
'
    assert_eq "R5/toplevel-survives" \
        "closes_issues=[1733] workflow_type=wf-code last_pushed_sha=kept session_model=claude-opus-5 created_at_stable=true" \
        "$NODE_OUT"
fi

echo "== R6: gated steps before from_step get a synthetic plan_approval =="
if run_case "R6/gated-approval-synthesised"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const CA2 = require("./hooks/workflow-state/completion-approval");
const st = S.readState(sid);
const i = S.VALID_STEPS.indexOf("detail");
const gatedBefore = CA2.APPROVAL_GATED_STEPS.filter((s) => S.VALID_STEPS.indexOf(s) < i);
const resetApprovals = rd().events.filter((e) => e.kind === "plan_approval" && e.origin === "reset-sentinel");
const missing = gatedBefore.filter((s) => !resetApprovals.some((e) => e.step === s));
const one = resetApprovals[0] || {};
console.log("gated_before=" + gatedBefore.join(",") +
            " missing=" + (missing.join(",") || "0") +
            " hash_status=" + one.artifact_hash_status +
            " provenance=" + one.provenance);
'
    assert_eq "R6/gated-approval-synthesised" \
        "gated_before=outline missing=0 hash_status=not-applicable provenance=declared" "$NODE_OUT"
fi

echo "== R7: history from before the reset is still readable (the point of #1733) =="
if run_case "R7/pre-reset-history-readable"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const ev = rd().events.filter((e) => e.kind === "step_status" && e.step === "detail");
console.log("detail_status_events=" + ev.length +
            " sequence=" + ev.map((e) => e.status).join(">") +
            " first_provenance=" + ev[0].provenance);
'
    assert_eq "R7/pre-reset-history-readable" \
        "detail_status_events=2 sequence=complete>pending first_provenance=observed" "$NODE_OUT"
fi

echo "== R8: RESET_FROM twice is additive, never destructive =="
if run_case "R8/double-reset"; then
    next_sid
    nodejs "$SID" "$SEED_JS$RESET_JS"'
const n1 = rd().events.length;
'"$RESET_JS"'
const n2 = rd().events.length;
const resets = rd().events.filter((e) => e.kind === "reset").length;
console.log("grew=" + (n2 > n1) + " reset_anchors=" + resets +
            " contiguous=" + rd().events.every((e, i) => e.seq === i + 1));
'
    assert_eq "R8/double-reset" "grew=true reset_anchors=2 contiguous=true" "$NODE_OUT"
fi

echo "== R9: workflow_init completion resets downstream with the same batch shape =="
if run_case "R9/workflow-init-downstream-reset"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
const mh = require("./hooks/workflow-mark/mark-step-handler");
const before = rd().events.length;
mh.handle({
  cmd: "echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\"",
  sessionId: sid, pushMessage: () => {}, signalFatal: () => {}, repoCwd: process.cwd(),
});
const st = S.readState(sid);
const ev = rd().events;
const cleared = ev.filter((e) => e.kind === "step_annotations_cleared" && e.origin === "workflow-init-downstream-reset");
console.log("append_only=" + (ev.length > before) +
            " cleared_events=" + (cleared.length > 0) +
            " review_tests=" + st.steps.review_tests.status +
            " token_gone=" + !("token" in st.steps.review_tests) +
            " closes_issues=" + JSON.stringify(st.closes_issues));
'
    assert_eq "R9/workflow-init-downstream-reset" \
        "append_only=true cleared_events=true review_tests=pending token_gone=true closes_issues=[1733]" "$NODE_OUT"
fi

echo "== R10: reset_reason from a post-merge reset is readable as an annotation =="
if run_case "R10/reset-reason-annotation"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "branching_complete", "complete");
S.markStep(sid, "branching_complete", "pending", { reset_reason: "post-merge" });
const st = S.readState(sid);
const ev = rd().events.find((e) => e.kind === "step_annotation" && e.key === "reset_reason");
console.log("projected=" + st.steps.branching_complete.reset_reason +
            " event_step=" + (ev && ev.step) + " status=" + st.steps.branching_complete.status);
'
    assert_eq "R10/reset-reason-annotation" \
        "projected=post-merge event_step=branching_complete status=pending" "$NODE_OUT"
fi

# reset_to <target> <reason> — the RESET_JS body with the step and reason parameterised.
# Every case below resets from a DIFFERENT position, because "reset from detail" is the
# comfortable middle of the range: it has predecessors to preserve and successors to
# clear, so it cannot expose an off-by-one at either end of VALID_STEPS, nor the
# rejection paths that a malformed sentinel takes.
reset_to() { # <target-step> <reason>
    printf '%s' '{
  const rh = require("./hooks/workflow-mark/reset-handler");
  const msgs = [];
  let fatal = null;
  rh.handle({
    cmd: "echo \"<<WORKFLOW_RESET_FROM_'"$1"': '"$2"'>>\"",
    sessionId: sid, pushMessage: (m) => msgs.push(String(m)), signalFatal: (m) => { fatal = String(m); },
    repoCwd: process.cwd(),
  });
  globalThis.__msgs = msgs; globalThis.__fatal = fatal;
}
'
}

echo "== R11: reset from the FIRST step clears everything downstream and keeps the trail =="
if run_case "R11/reset-from-first-step"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
const before = rd().events;
const beforeJson = JSON.stringify(before);
'"$(reset_to workflow_init 'start over')"'
const st = S.readState(sid);
const after = rd().events;
const anyComplete = Object.keys(st.steps).filter((s) => st.steps[s].status === "complete");
console.log([
  "prefix_identical=" + (JSON.stringify(after.slice(0, before.length)) === beforeJson),
  "reset_event=" + after.filter((e) => e.kind === "reset" && e.from_step === "workflow_init").length,
  "still_complete=" + (anyComplete.join(",") || "-"),
  "settings_kept=" + (st.workflow_type === "wf-code" && JSON.stringify(st.closes_issues) === "[1733]"),
  "seq_contiguous=" + after.every((e, i) => e.seq === i + 1),
].join(" "));
'
    # Nothing survives as complete: workflow_init itself is reset, and it is the first
    # element of VALID_STEPS, so "everything after the target" is the entire plan.
    assert_eq "R11/reset-from-first-step" \
        "prefix_identical=true reset_event=1 still_complete=- settings_kept=true seq_contiguous=true" "$NODE_OUT"
fi

echo "== R12: reset from the TERMINAL step is accepted and touches nothing upstream =="
if run_case "R12/reset-from-terminal-step"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
// buildResetEvents (reset-handler.js) unconditionally re-asserts EVERY step before
// from_step as "complete" (sanctioned #1133 behaviour), so it always re-stamps
// updated_at even for a step that was already complete. SEED_JS alone leaves several
// steps pending, so this case pre-completes every step except final_report itself —
// otherwise the reset would flip pending -> complete on its own and the assertion
// below would not be testing "no downstream effect", just "SEED_JS was incomplete".
const statusesOf = (steps) => {
  const out = {};
  for (const k of Object.keys(steps)) out[k] = steps[k].status;
  return out;
};
for (const s of S.VALID_STEPS) {
  if (s !== "final_report") S.markStep(sid, s, "complete");
}
const beforeStatuses = JSON.stringify(statusesOf(S.readState(sid).steps));
'"$(reset_to final_report 'redo the report')"'
const st = S.readState(sid);
const ev = rd().events;
// final_report has no successors, so a reset from it re-asserts every preceding step
// but must never CHANGE a status: everything preceding was already complete, and
// final_report itself was already (and stays) pending. updated_at is deliberately NOT
// compared — the re-assertion legitimately re-stamps it on every reset, upstream or not.
console.log([
  "statuses_unchanged=" + (JSON.stringify(statusesOf(st.steps)) === beforeStatuses),
  "reset_event=" + ev.filter((e) => e.kind === "reset" && e.from_step === "final_report").length,
  "fatal=" + globalThis.__fatal,
  "seq_contiguous=" + ev.every((e, i) => e.seq === i + 1),
].join(" "));
'
    assert_eq "R12/reset-from-terminal-step" \
        "statuses_unchanged=true reset_event=1 fatal=null seq_contiguous=true" "$NODE_OUT"
fi

echo "== R13: an unknown or malformed step name is refused, byte-for-byte =="
if run_case "R13/unknown-step-refused"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
const rh = require("./hooks/workflow-mark/reset-handler");
const before = raw();
const results = [];
// Near-misses on purpose: casing, plural, a prefix of a real step, a path traversal
// shape, and the empty target. A reset that accepts any of these rewrites the plan from
// a step that does not exist — every downstream step is "after" it.
["Detail", "details", "deta", "not_a_step", "../detail", "", "detail extra"].forEach((target, i) => {
  let fatal = null;
  const msgs = [];
  rh.handle({
    cmd: "echo \"<<WORKFLOW_RESET_FROM_" + target + ": reason here>>\"",
    sessionId: sid, pushMessage: (m) => msgs.push(String(m)), signalFatal: (m) => { fatal = String(m); },
    repoCwd: process.cwd(),
  });
  const resets = rd().events.filter((e) => e.kind === "reset").length;
  results.push(i + ":resets=" + resets);
});
console.log((results.join(" ") + " unchanged=" + (raw() === before)));
'
    assert_eq "R13/unknown-step-refused" \
        "0:resets=0 1:resets=0 2:resets=0 3:resets=0 4:resets=0 5:resets=0 6:resets=0 unchanged=true" \
        "$NODE_OUT"
fi

echo "== R14: a missing or empty reason is refused (the reason is the audit record) =="
if run_case "R14/invalid-reason-refused"; then
    next_sid
    nodejs "$SID" "$SEED_JS"'
const rh = require("./hooks/workflow-mark/reset-handler");
const before = raw();
const results = [];
// The bare form and the empty/whitespace reason are exactly the cases the sentinel
// contract calls out: a reset with no stated reason leaves an anchor that explains
// nothing, which is the same as no anchor at all.
["<<WORKFLOW_RESET_FROM_detail>>", "<<WORKFLOW_RESET_FROM_detail: >>", "<<WORKFLOW_RESET_FROM_detail:>>"].forEach((s, i) => {
  rh.handle({
    cmd: "echo \"" + s + "\"", sessionId: sid,
    pushMessage: () => {}, signalFatal: () => {}, repoCwd: process.cwd(),
  });
  results.push(i + ":resets=" + rd().events.filter((e) => e.kind === "reset").length);
});
console.log(results.join(" ") + " unchanged=" + (raw() === before));
'
    assert_eq "R14/invalid-reason-refused" \
        "0:resets=0 1:resets=0 2:resets=0 unchanged=true" "$NODE_OUT"
fi

echo "== R15: a reset for a session with no state file creates nothing =="
if run_case "R15/missing-state-file"; then
    next_sid
    # No seed at all: the sentinel arrives before /workflow-init ever ran. Materialising a
    # state file here would fabricate a session whose entire history is a reset.
    nodejs "$SID" "$PRE"'
const rh = require("./hooks/workflow-mark/reset-handler");
const existedBefore = fs.existsSync(sp());
let fatal = null;
rh.handle({
  cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: no session yet>>\"",
  sessionId: sid, pushMessage: () => {}, signalFatal: (m) => { fatal = String(m); }, repoCwd: process.cwd(),
});
const existsAfter = fs.existsSync(sp());
const events = existsAfter ? rd().events.length : 0;
console.log("before=" + existedBefore + " after=" + existsAfter + " events=" + events);
'
    assert_eq "R15/missing-state-file" "before=false after=false events=0" "$NODE_OUT"
fi

echo "== R16: a corrupt state file is not overwritten by a reset =="
if run_case "R16/corrupt-state-file"; then
    next_sid
    printf '%s' '{ "version": 2, "events": [ THIS IS NOT JSON' > "$WF/$SID.json"
    nodejs "$SID" "$PRE"'
const rh = require("./hooks/workflow-mark/reset-handler");
const before = raw();
rh.handle({
  cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: on corrupt state>>\"",
  sessionId: sid, pushMessage: () => {}, signalFatal: () => {}, repoCwd: process.cwd(),
});
// Rewriting here would destroy the only copy of whatever the file was going to be
// recovered from. Fail closed, leave the bytes.
console.log("unchanged=" + (raw() === before));
'
    assert_eq "R16/corrupt-state-file" "unchanged=true" "$NODE_OUT"
fi

echo "== R17: two concurrent RESET_FROM processes both land — neither anchor is lost =="
if run_case "R17/concurrent-reset"; then
    next_sid
    SID_R17="$SID"
    nodejs "$SID_R17" "$SEED_JS"'console.log("SEEDED");'
    assert_eq "R17/seed" "SEEDED" "$NODE_OUT"

    # The sentinel fires from a PreToolUse hook, so two Bash calls in flight at once (or a
    # reset racing the PostToolUse recorder) genuinely put two reset batches on the same
    # file. Read-modify-write of the WHOLE state is exactly where a lost update hides: the
    # loser's anchor vanishes and the audit trail claims one reset where there were two.
    R17_JS="$PRE"'
const rh = require("./hooks/workflow-mark/reset-handler");
rh.handle({
  cmd: "echo \"<<WORKFLOW_RESET_FROM_detail: " + process.env.REASON + ">>\"",
  sessionId: sid, pushMessage: () => {}, signalFatal: () => {}, repoCwd: process.cwd(),
});
console.log("DONE");
'
    for reason in alpha bravo; do
        (cd "$AGENTS_DIR" && env \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_R17" REASON="$reason" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$R17_JS" \
            >"$TMPROOT/r17-$reason.out" 2>&1) &
    done
    wait

    R17_INCOMPLETE="$(grep -L '^DONE$' "$TMPROOT"/r17-*.out 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "R17/both-processes-finished" "0" "$R17_INCOMPLETE"

    nodejs "$SID_R17" "$PRE"'
const st = S.readState(sid);
const ev = rd().events;
const resets = ev.filter((e) => e.kind === "reset");
console.log([
  "anchors=" + resets.length,
  "reasons=" + resets.map((e) => e.reason).sort().join(","),
  "contiguous=" + ev.every((e, i) => e.seq === i + 1),
  "unique_seq=" + (new Set(ev.map((e) => e.seq)).size === ev.length),
  "settings_kept=" + (st.workflow_type === "wf-code" && JSON.stringify(st.closes_issues) === "[1733]"),
].join(" "));
'
    assert_eq "R17/concurrent-reset" \
        "anchors=2 reasons=alpha,bravo contiguous=true unique_seq=true settings_kept=true" "$NODE_OUT"
fi

finish "reset-from"

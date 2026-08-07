#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/class-members-history.sh
# Tests: hooks/workflow-state/state-io/session-fields.js, hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js
# Tags: workflow-state, event-stream, append-only, history, plan-approval, complexity, session-model, scope:issue-specific, pwsh-not-required, TL2
#
# "Every timestamped fact becomes an event" is a CLASS statement, and step_status is only
# its most visible member. The other three members — plan_approvals, complexity_evaluation
# and session_model — used to be read-modify-write top-level fields, i.e. exactly the
# overwrite semantics #1733 exists to remove. Covering step_status alone would leave the
# class half-migrated with a green suite (CPR-ORTH).
#
# Each member is asserted on the same two axes:
#   history    — the superseded record is still IN events[] after the second write
#   projection — `current` selects the right one (latest, except session_model: first)
#
# session_model is the asymmetric member on purpose: it is write-once identity, so its
# rule is FIRST-writer-wins and the race case below is what makes that claim mean
# anything — a lock-free implementation passes the sequential case and fails the race.
#
# TL3 gap (what this file does NOT catch):
# - the real SessionStart / confirm-sentinel hooks that call these writers; the writers
#   are invoked as modules here.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh.

CASE_TAG="cls"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== H1: two complexity evaluations -> both events kept, current holds the latest =="
if run_case "H1/complexity-history"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.recordComplexityEvaluation(sid, "low", ["one-file"]);
sleep(5);
S.recordComplexityEvaluation(sid, "high", ["many-files", "hook-change"]);
const ev = evs("complexity_evaluation");
console.log([
  "n=" + ev.length,
  "levels=" + ev.map((e) => e.level).join(">"),
  "first_signals=" + JSON.stringify(ev[0] && ev[0].signals),
  "distinct_at=" + new Set(ev.map((e) => e.at)).size,
  "current=" + (cur().complexity_evaluation || {}).level,
  "current_signals=" + JSON.stringify((cur().complexity_evaluation || {}).signals),
  "toplevel=" + Object.prototype.hasOwnProperty.call(rd(), "complexity_evaluation"),
].join(" "));
'
    assert_eq "H1/complexity-history" \
        'n=2 levels=low>high first_signals=["one-file"] distinct_at=2 current=high current_signals=["many-files","hook-change"] toplevel=false' \
        "$NODE_OUT"
fi

echo "== H2: two approvals of the SAME step -> both events kept, current holds the latest =="
if run_case "H2/plan-approval-history"; then
    next_sid
    nodejs "$SID" "$PRE"'
const CA = require("./hooks/workflow-state/completion-approval");
CA.recordPlanApproval(sid, "detail", { source: "confirm-sentinel", reason: "first pass", artifactSha: "aaa111" });
sleep(5);
// Re-approval after the artifact changed: the SECOND record is the operative one, but
// the first must stay readable — it is the evidence that an earlier hash was approved.
CA.recordPlanApproval(sid, "detail", { source: "confirm-sentinel", reason: "re-approved after edit", artifactSha: "bbb222" });
const ev = evs("plan_approval").filter((e) => e.step === "detail");
const curPa = (cur().plan_approvals || {}).detail || {};
console.log([
  "n=" + ev.length,
  "shas=" + ev.map((e) => e.artifact_sha256).join(">"),
  "reasons=" + ev.map((e) => e.reason).join(">"),
  "current_sha=" + curPa.artifact_sha256,
  "current_reason=" + curPa.reason,
  "toplevel=" + Object.prototype.hasOwnProperty.call(rd(), "plan_approvals"),
].join(" "));
'
    assert_eq "H2/plan-approval-history" \
        "n=2 shas=aaa111>bbb222 reasons=first pass>re-approved after edit current_sha=bbb222 current_reason=re-approved after edit toplevel=false" \
        "$NODE_OUT"
fi

echo "== H3: revoking an approval removes it from current but never from the audit trail =="
if run_case "H3/approval-revocation-auditable"; then
    next_sid
    nodejs "$SID" "$PRE"'
const CA = require("./hooks/workflow-state/completion-approval");
CA.recordPlanApproval(sid, "outline", { source: "confirm-sentinel", reason: "approved", artifactSha: "ccc333" });
sleep(5);
S.appendEvents(sid, [{ kind: "plan_approval_revoked", step: "outline", reason: "artifact changed after approval", provenance: "observed", origin: "completion-boundary" }]);
const approvals = evs("plan_approval").filter((e) => e.step === "outline");
const revokes = evs("plan_approval_revoked").filter((e) => e.step === "outline");
const curPa = cur().plan_approvals || {};
// The approval event is still there with its hash: a revocation is an ADDITIONAL fact,
// not an eraser. Without this, "was this ever approved, and on what?" becomes
// unanswerable the moment the approval is withdrawn.
console.log([
  "approvals=" + approvals.length,
  "approval_sha=" + (approvals[0] || {}).artifact_sha256,
  "revokes=" + revokes.length,
  "revoke_reason=" + (revokes[0] || {}).reason,
  "current_has_outline=" + Object.prototype.hasOwnProperty.call(curPa, "outline"),
  "order=" + (approvals[0].seq < revokes[0].seq),
].join(" "));
'
    assert_eq "H3/approval-revocation-auditable" \
        "approvals=1 approval_sha=ccc333 revokes=1 revoke_reason=artifact changed after approval current_has_outline=false order=true" \
        "$NODE_OUT"
fi

echo "== H4: recording the session model twice keeps exactly the FIRST event =="
if run_case "H4/session-model-write-once-sequential"; then
    next_sid
    nodejs "$SID" "$PRE"'
const a = S.recordSessionModel(sid, { id: "model-first", source: "session-start" });
sleep(5);
const b = S.recordSessionModel(sid, { id: "model-second", source: "stop-hook" });
const ev = evs("session_model");
console.log([
  "first_recorded=" + a.recorded,
  "second_recorded=" + b.recorded,
  "n=" + ev.length,
  "id=" + (ev[0] || {}).id,
  "source=" + (ev[0] || {}).source,
  "current=" + (cur().session_model || {}).id,
  "toplevel=" + Object.prototype.hasOwnProperty.call(rd(), "session_model"),
].join(" "));
'
    assert_eq "H4/session-model-write-once-sequential" \
        "first_recorded=true second_recorded=false n=1 id=model-first source=session-start current=model-first toplevel=false" \
        "$NODE_OUT"
fi

echo "== H5: 8 processes racing to record the session model -> exactly one event survives =="
if run_case "H5/session-model-write-once-race"; then
    next_sid
    SID_H5="$SID"
    nodejs "$SID_H5" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "H5/seed" "SEEDED" "$NODE_OUT"

    # Read-modify-write without a lock passes H4 and fails here: two processes that both
    # observe "no session_model yet" would each append their own identity event, and the
    # session's model identity would depend on scheduling.
    H5_JS='const S = require("./hooks/workflow-state/state-io");
const sid = process.env.SID;
try { S.recordSessionModel(sid, { id: "model-" + process.env.WNO, source: "race" }); }
catch (e) { console.log("THREW:" + e.name); }
console.log("DONE");
'
    for i in 1 2 3 4 5 6 7 8; do
        (cd "$AGENTS_DIR" && env \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_H5" WNO="$i" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$H5_JS" \
            >"$TMPROOT/h5-$i.out" 2>&1) &
    done
    wait

    H5_INCOMPLETE=0
    for i in 1 2 3 4 5 6 7 8; do
        grep -q '^DONE$' "$TMPROOT/h5-$i.out" || H5_INCOMPLETE=$((H5_INCOMPLETE + 1))
    done
    assert_eq "H5/all-racers-finished" "0" "$H5_INCOMPLETE"

    nodejs "$SID_H5" "$PRE"'
const ev = evs("session_model");
const st = rd();
const seqs = st.events.map((e) => e.seq);
console.log([
  "n=" + ev.length,
  "current_matches_event=" + (ev.length === 1 && (cur().session_model || {}).id === ev[0].id),
  "id_is_a_racer=" + (ev.length === 1 && /^model-[1-8]$/.test(String(ev[0].id))),
  "contiguous=" + seqs.every((s, i) => s === i + 1),
].join(" "));
'
    assert_eq "H5/session-model-write-once-race" \
        "n=1 current_matches_event=true id_is_a_racer=true contiguous=true" "$NODE_OUT"
fi

echo "== H6: the whole class is event-backed — no member is readable from the top level =="
if run_case "H6/class-members-not-top-level"; then
    next_sid
    nodejs "$SID" "$PRE"'
const CA = require("./hooks/workflow-state/completion-approval");
S.recordComplexityEvaluation(sid, "high", ["x"]);
S.recordSessionModel(sid, { id: "model-x", source: "session-start" });
CA.recordPlanApproval(sid, "detail", { source: "confirm-sentinel", reason: "ok", artifactSha: "ddd444" });
const disk = rd();
const MEMBERS = ["complexity_evaluation", "session_model", "plan_approvals"];
const leaked = MEMBERS.filter((k) => Object.prototype.hasOwnProperty.call(disk, k));
// ...and each member is reconstructible from events[] alone: deleting `current` from the
// parsed file and re-reading must give back the same projection.
const kinds = ["complexity_evaluation", "session_model", "plan_approval"];
const missing = kinds.filter((k) => !disk.events.some((e) => e.kind === k));
const projected = MEMBERS.filter((k) => (cur() || {})[k] === undefined);
console.log("leaked=" + (leaked.join(",") || "-") + " missing_events=" + (missing.join(",") || "-") + " unprojected=" + (projected.join(",") || "-"));
'
    assert_eq "H6/class-members-not-top-level" "leaked=- missing_events=- unprojected=-" "$NODE_OUT"
fi

feature_banner
finish "class-members-history"

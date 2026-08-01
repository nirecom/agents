#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/provenance.sh
# Tests: hooks/workflow-state/effective-state.js, hooks/workflow-state/state-io/events.js, hooks/workflow-mark/not-needed-handlers.js
# Tags: workflow-state, event-stream, provenance, effective-state, genuine-complete, scope:issue-specific, pwsh-not-required, TL2
#
# Before #1733, "did this step really complete or did something synthesise it?" was
# inferred from a raw-JSON heuristic: the key exists AND updated_at is a non-empty
# string. `provenance` replaces that heuristic with a recorded fact, and the migration
# must be BEHAVIOUR-PRESERVING: observed/declared keep counting as genuine (a
# RESET_FROM force-complete did, and still does), only migration- and inheritance-
# synthesised records are excluded. Both verdicts of the classifier are covered, not
# just the newly-excluded one (test-design.md "Classifier / guard cases").
#
# The classifier is observed through its ONE live consumer, evaluateInheritance's S3
# rule (see the genuine() contract in common.sh) — the subject is therefore always
# clarify_intent, and `true` below means "S3 stopped inheritance", which under this
# harness's empty WORKFLOW_PLANS_DIR is exactly the classifier's verdict.
#
# TL3 gap (what this test does NOT catch):
# - the other consumers of the classifier (evidence resolution, next-step advisories)
#   are not driven end-to-end here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="prov"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"

echo "== G1: an ordinary markStep complete is genuine (observed) =="
if run_case "G1/observed-is-genuine"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
S.markStep(sid, GENUINE_SUBJECT, "complete");
console.log("genuine=" + genuine(sid));
'
    assert_eq "G1/observed-is-genuine" "genuine=true" "$NODE_OUT"
fi

echo "== G2: a declared complete (RESET_FROM force-complete) is genuine — behaviour preserved =="
if run_case "G2/declared-is-genuine"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
const E = require("./hooks/workflow-state/state-io/events");
E.appendEvents(sid, [{ kind: "step_status", step: GENUINE_SUBJECT, status: "complete",
                       provenance: "declared", origin: "reset-sentinel" }],
               { sanctioned: "reset-sentinel", reason: "provenance fixture" });
console.log("genuine=" + genuine(sid));
'
    assert_eq "G2/declared-is-genuine" "genuine=true" "$NODE_OUT"
fi

echo "== G3: a backfilled complete is NOT genuine =="
if run_case "G3/backfilled-not-genuine"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
const E = require("./hooks/workflow-state/state-io/events");
E.appendEvents(sid, [{ kind: "step_status", step: GENUINE_SUBJECT, status: "complete",
                       provenance: "backfilled", origin: "session-inherit",
                       inherited_from: "old-sid" }]);
console.log("genuine=" + genuine(sid) +
            " projects_complete=" + (cur().steps[GENUINE_SUBJECT].status === "complete"));
'
    # The step still PROJECTS as complete — only the genuineness signal differs.
    assert_eq "G3/backfilled-not-genuine" "genuine=false projects_complete=true" "$NODE_OUT"
fi

echo "== G4: the LATEST step_status decides, not any earlier one =="
if run_case "G4/latest-event-decides"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
const E = require("./hooks/workflow-state/state-io/events");
S.markStep(sid, GENUINE_SUBJECT, "complete");
const genuineFirst = genuine(sid);
E.appendEvents(sid, [{ kind: "step_status", step: GENUINE_SUBJECT, status: "complete",
                       provenance: "backfilled", origin: "session-inherit" }]);
const genuineAfter = genuine(sid);
console.log("after_observed=" + genuineFirst + " after_backfilled=" + genuineAfter);
'
    assert_eq "G4/latest-event-decides" "after_observed=true after_backfilled=false" "$NODE_OUT"
fi

echo "== G5: a non-complete latest status is not genuine-complete, whatever the provenance =="
if run_case "G5/non-complete-verdicts"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
const out = [];
for (const st of ["pending", "in_progress", "skipped"]) {
  S.markStep(sid, GENUINE_SUBJECT, st);
  out.push(st + "=" + genuine(sid));
}
console.log(out.join(" "));
'
    assert_eq "G5/non-complete-verdicts" "pending=false in_progress=false skipped=false" "$NODE_OUT"
fi

echo "== G6: a step with no event at all is not genuine (and does not throw) =="
if run_case "G6/absent-step"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
// Some other step complete, the subject untouched: the classifier must answer for the
// subject alone rather than for "anything happened in this session".
S.markStep(sid, "workflow_init", "complete");
let verdict;
try { verdict = "genuine=" + genuine(sid); } catch (e) { verdict = "THREW:" + e.name; }
let missing;
try { missing = "no_state=" + genuine("sid1733-absent-999"); } catch (e) { missing = "THREW:" + e.name; }
console.log(verdict + " " + missing);
'
    assert_eq "G6/absent-step" "genuine=false no_state=false" "$NODE_OUT"
fi

echo "== G7: after migration, a v1 timestamp keeps its verdict and a null timestamp loses it =="
if run_case "G7/v1-timestamped-stays-genuine"; then
    next_sid
    SID_G7A="$SID"
    (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" ordering) > "$WF/$SID_G7A.json"
    next_sid
    SID_G7B="$SID"
    # Same fixture, one field changed: clarify_intent loses its timestamp. That single
    # difference is the whole pre-#1733 heuristic ("raw key + non-empty updated_at"),
    # so the pair isolates it from every other property of the fixture.
    (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" ordering) \
        | (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node -e '
let buf = ""; process.stdin.on("data", (d) => { buf += d; });
process.stdin.on("end", () => { const s = JSON.parse(buf); s.steps.clarify_intent.updated_at = null;
  process.stdout.write(JSON.stringify(s, null, 2)); });
') > "$WF/$SID_G7B.json"
    nodejs_env "SID_A=$SID_G7A SID_B=$SID_G7B" "$SID_G7A" "$PRE$GENUINE_JS"'
// A: updated_at set -> observed -> genuine. B: updated_at null on a non-pending entry
// -> backfilled + at_estimated -> NOT genuine.
console.log("timestamped=" + genuine(process.env.SID_A) +
            " null_timestamp=" + genuine(process.env.SID_B));
'
    assert_eq "G7/v1-timestamped-stays-genuine" "timestamped=true null_timestamp=false" "$NODE_OUT"
fi

echo "== G8: a *_NOT_NEEDED skip is recorded as declared, not observed =="
if run_case "G8/not-needed-is-declared"; then
    next_sid
    nodejs "$SID" "$PRE$GENUINE_JS"'
const NN = require("./hooks/workflow-mark/not-needed-handlers");
const msgs = [];
NN.handle({
  cmd: "echo \"<<WORKFLOW_RESEARCH_NOT_NEEDED: nothing to survey>>\"",
  sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: () => {}, repoCwd: process.cwd(),
});
const ev = rd().events.filter((e) => e.kind === "step_status" && e.step === "research").pop();
console.log("status=" + (ev && ev.status) + " provenance=" + (ev && ev.provenance) +
            " skip_reason=" + (cur().steps.research.skip_reason ? "present" : "absent"));
'
    assert_eq "G8/not-needed-is-declared" "status=skipped provenance=declared skip_reason=present" "$NODE_OUT"
fi

echo "== G9: control — the verdict tracks provenance, not the mere fact of a stop =="
if run_case "G9/adapter-control"; then
    next_sid
    # Without this control, every "genuine=true" above could be produced by an
    # evaluateInheritance that never looks at provenance at all: S3 has a second
    # conjunct (the missing plan artifact), and the harness pins it by keeping
    # WORKFLOW_PLANS_DIR empty. Restoring the artifact must flip the verdict, and
    # removing it again must flip it back — proving the pin is load-bearing and that
    # the observation is attributable to the classifier.
    nodejs "$SID" "$PRE$GENUINE_JS"'
S.markStep(sid, GENUINE_SUBJECT, "complete");
const noArtifact = genuine(sid);
plan_artifact(sid, true);
const withArtifact = genuine(sid);
plan_artifact(sid, false);
const again = genuine(sid);
console.log("no_artifact=" + noArtifact + " with_artifact=" + withArtifact + " restored=" + again);
'
    assert_eq "G9/adapter-control" "no_artifact=true with_artifact=false restored=true" "$NODE_OUT"
fi

finish "provenance"

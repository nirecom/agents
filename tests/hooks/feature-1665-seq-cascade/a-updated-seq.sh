#!/bin/bash
# tests/feature-1665-seq-cascade/a-updated-seq.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js
# Tags: workflow-state, updated-seq, causal-order, projection, batch-fold, scope:issue-specific, pwsh-not-required, TL1
#
# A — `steps[step].updated_seq` is derived from the FOLD LOOP POSITION, never
# from `e.seq`.
#
# WHY the distinction matters: appendEvents folds the batch (projectState(withBatch))
# BEFORE it assigns `seq`, so an implementation written as `= e.seq` yields
# `undefined` for every event in the batch being appended — and yet reads back
# correct forever after, because the persisted `current` cache is rewritten from a
# stream whose seq is already assigned. A4/A5 fold a SEQ-LESS array — the exact
# shape appendEvents hands the projector — so the regression cannot hide.

CASE_TAG=a
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# ---------------------------------------------------------------- A1/A2/A3/A6/A7
js_g '
const S = require(process.env.M_SIO);

// A1/A2: durable stream — every step entry must carry the seq of its LAST
// step_status event; never-touched steps stay null.
const sid = "seq1665-a1";
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete", { skip_reason: "n/a" });
S.markStep(sid, "workflow_init", "in_progress");
const st = S.readState(sid);
const last = {};
for (const e of st.events) if (e.kind === "step_status") last[e.step] = e.seq;
const bad = [];
for (const step of Object.keys(st.steps)) {
  const want = last[step] === undefined ? null : last[step];
  const got = st.steps[step].updated_seq === undefined ? "MISSING" : st.steps[step].updated_seq;
  if (got !== want) bad.push(step + ":want=" + want + ",got=" + got);
}
console.log("A1.mismatches=" + (bad.length ? bad.slice(0, 3).join("|") + " (" + bad.length + " total)" : "none"));
console.log("A1.workflow_init=" + JSON.stringify(st.steps.workflow_init.updated_seq));
console.log("A2.untouched=" + JSON.stringify(st.steps.final_report.updated_seq));

// A3: step_annotations_cleared rebuilds the entry — updated_seq must survive
// the rebuild (it is structure, not annotation).
const sid3 = "seq1665-a3";
S.markStep(sid3, "research", "complete", { skip_reason: "x" });
const before = S.readState(sid3).steps.research.updated_seq;
S.appendEvents(sid3, {
  kind: "step_annotations_cleared", step: "research",
  provenance: "declared", origin: "test-1665",
});
const after = S.readState(sid3).steps.research;
console.log("A3.before=" + JSON.stringify(before));
console.log("A3.after=" + JSON.stringify(after.updated_seq));
console.log("A3.skip_reason_gone=" + (after.skip_reason === undefined));

// A6: builder-form append — the value must be right for the event appended in
// THIS batch, not only on the next read.
const sid6 = "seq1665-a6";
S.markStep(sid6, "workflow_init", "complete");
S.appendEvents(sid6, () => [{
  kind: "step_status", step: "docs", status: "complete",
  provenance: "observed", origin: "test-1665",
}]);
const st6 = S.readState(sid6);
console.log("A6.docs=" + JSON.stringify(st6.steps.docs.updated_seq));
console.log("A6.stream_seq=" + JSON.stringify(st6.events[st6.events.length - 1].seq));

// A7: updated_seq is ADDITIVE — updated_at is not replaced.
console.log("A7.updated_at_type=" + typeof st6.steps.docs.updated_at);
'
if require_js_ok "A: durable-stream probe"; then
    assert_js "A1 every entry carries its last step_status seq" A1.mismatches "none"
    assert_js "A1 re-marked step takes the LATER seq" A1.workflow_init "4"
    assert_js "A2 never-settled step has null updated_seq" A2.untouched "null"
    assert_js "A3 seq before annotations_cleared" A3.before "1"
    assert_js "A3 seq survives annotations_cleared" A3.after "1"
    assert_js "A3 annotations_cleared really dropped the annotation" A3.skip_reason_gone "true"
    assert_js "A6 in-batch append projects the batch seq" A6.docs "2"
    assert_js "A6 stream seq agrees with the projection" A6.stream_seq "2"
    assert_js "A7 updated_at is still projected alongside" A7.updated_at_type "string"
fi

# ------------------------------------------------------------------- A4/A5
# The regression probe. projectState is called directly on a SEQ-LESS events
# array — the exact shape events.js hands to projectState(withBatch) — so an
# implementation reading `e.seq` produces `undefined` here and cannot pass.
js_g '
const P = require(process.env.M_PROJ);
const mk = (step, status) => ({
  kind: "step_status", step, status,
  provenance: "observed", origin: "test-1665", at: "2026-01-01T00:00:00.000Z",
});

const st = P.projectState({ events: [mk("workflow_init", "complete"), mk("run_tests", "pending")] });
console.log("A4.first=" + JSON.stringify(st.steps.workflow_init.updated_seq));
console.log("A4.second=" + JSON.stringify(st.steps.run_tests.updated_seq));
console.log("A4.type=" + typeof st.steps.workflow_init.updated_seq);

// A5: the counter is the ARRAY INDEX + 1, not a filtered running count. The
// fold skips non-object records (continue) without consuming a position, so a
// hand-rolled counter would report 1 where the stream position is 2.
const st2 = P.projectState({ events: [null, mk("docs", "complete")] });
console.log("A5.docs=" + JSON.stringify(st2.steps.docs.updated_seq));
'
if require_js_ok "A: seq-less batch probe"; then
    assert_js "A4 seq-less batch: first event projects position 1" A4.first "1"
    assert_js "A4 seq-less batch: second event projects position 2" A4.second "2"
    assert_js "A4 seq-less batch yields a number, not undefined" A4.type "number"
    assert_js "A5 position is the array index, not a filtered counter" A5.docs "2"
fi

finish

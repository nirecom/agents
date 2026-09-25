#!/bin/bash
# tests/feature-1665-seq-cascade/b-entry-shape-parity.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, updated-seq, entry-shape, orthogonality, scope:issue-specific, pwsh-not-required, TL1
#
# B — CPR-ORTH: every site that CONSTRUCTS a step entry must produce the same
# key set. Three such sites exist today (emptyStepEntry, the
# step_annotations_cleared rebuild, and the legacy-v1 read-default filler); a
# new projection field added to only one of them is exactly the drift this case
# is here to catch, because a caller reading `updated_seq` off an entry built by
# the forgotten site sees `undefined` and silently takes the fail-open branch.

CASE_TAG=b
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

js_g '
const fs = require("fs");
const path = require("path");
const P = require(process.env.M_PROJ);
const S = require(process.env.M_SIO);
const keys = (o) => Object.keys(o).sort().join(",");
const at = "2026-01-01T00:00:00.000Z";

// Site 1 — emptyStepEntry, reached by folding an empty stream.
const empty = P.projectState({ events: [] });
console.log("B1.keys=" + keys(empty.steps.run_tests));

// Site 2 — the step_annotations_cleared rebuild.
const cleared = P.projectState({ events: [
  { kind: "step_status", step: "docs", status: "complete", provenance: "observed", origin: "t", at },
  { kind: "step_annotation", step: "docs", key: "skip_reason", value: "x", provenance: "observed", origin: "t", at },
  { kind: "step_annotations_cleared", step: "docs", provenance: "observed", origin: "t", at },
]});
console.log("B2.keys=" + keys(cleared.steps.docs));
console.log("B2.updated_seq=" + JSON.stringify(cleared.steps.docs.updated_seq));
console.log("B2.annotation_gone=" + (cleared.steps.docs.skip_reason === undefined));

// Site 3 — applyLegacyV1ReadDefaults, which fabricates entries for steps the
// v1 file never mentioned.
const sid = "seq1665-b3";
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json"), JSON.stringify({
  session_id: sid,
  created_at: at,
  workflow_type: "wf-code",
  steps: { research: { status: "complete", updated_at: at } },
}));
const st = S.readState(sid);
console.log("B3.keys=" + keys(st.steps.workflow_init));
console.log("B3.status=" + st.steps.workflow_init.status);

console.log("B4.parity=" + (
  keys(empty.steps.run_tests) === keys(cleared.steps.docs) &&
  keys(cleared.steps.docs) === keys(st.steps.workflow_init)
));
'

if require_js_ok "B: entry-shape probe"; then
    assert_js "B1 emptyStepEntry carries status+updated_at+updated_seq" B1.keys "status,updated_at,updated_seq"
    assert_js "B2 annotations_cleared rebuild carries the same keys" B2.keys "status,updated_at,updated_seq"
    assert_js "B2 rebuild preserves the settled seq" B2.updated_seq "1"
    assert_js "B2 rebuild really cleared the annotation (non-vacuity)" B2.annotation_gone "true"
    assert_js "B3 legacy-v1 read default carries the same keys" B3.keys "status,updated_at,updated_seq"
    assert_js "B3 legacy-v1 default path really ran (non-vacuity)" B3.status "complete"
    assert_js "B4 all three construction sites agree" B4.parity "true"
fi

finish

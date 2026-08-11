#!/bin/bash
# tests/feature-1665-seq-cascade/d-reserved-annotation.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/inheritance/apply.js
# Tags: workflow-state, updated-seq, reserved-keys, guard, orthogonality, scope:issue-specific, pwsh-not-required, TL1
#
# D — `updated_seq` is STRUCTURE, so it must be reserved at all three sites that
# can turn an arbitrary key into a step annotation.
#
# WHY: an annotation named `updated_seq` would overwrite the projected fold
# position with an attacker- or migration-supplied number, and the cascade in
# case E trusts that number to decide which steps get reset. The three sites are
# deliberately asymmetric in HOW they refuse (throw / silently skip / drop),
# because their callers are: a validated event producer, a convenience API, and a
# pure data converter respectively.
#
# Classifier coverage (CPR-ORTH): every reserved key is checked, and a sanctioned
# annotation key is checked too — a guard that rejects everything is as broken as
# one that rejects nothing.

CASE_TAG=d
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

js_g '
const S = require(process.env.M_SIO);
const E = require(process.env.M_EVT);
const V = require(process.env.M_V1V2);
const A = require(process.env.M_INH);
const at = "2026-01-01T00:00:00.000Z";
const t = (fn) => { try { fn(); return "no-throw"; } catch (e) { return e.name; } };

// D1 — validateEvent rejects every reserved key, accepts a sanctioned one.
const mkAnn = (key) => ({
  kind: "step_annotation", step: "docs", key, value: 1,
  provenance: "observed", origin: "test-1665", at,
});
for (const k of ["status", "updated_at", "started_at", "updated_seq"]) {
  console.log("D1." + k + "=" + t(() => E.validateEvent(mkAnn(k))));
}
console.log("D1.allowed=" + t(() => E.validateEvent(mkAnn("skip_reason"))));
console.log("D1.append=" + t(() => S.appendEvents("seq1665-d1", mkAnn("updated_seq"))));

// D2 — markStep extraFields SILENTLY skips structure keys (its callers pass
// whole entry-shaped objects; throwing would break them), while a real
// annotation still lands.
const sid = "seq1665-d2";
S.markStep(sid, "docs", "complete", { updated_seq: 999, started_at: "x", skip_reason: "keep" });
const st = S.readState(sid);
console.log("D2.updated_seq=" + JSON.stringify(st.steps.docs.updated_seq));
console.log("D2.ann_keys=" + st.events.filter((e) => e.kind === "step_annotation").map((e) => e.key).join(","));
console.log("D2.skip_reason=" + JSON.stringify(st.steps.docs.skip_reason));

// D3 — the v1 entry converter drops structure keys (shared with inheritance).
const evs = V.convertV1AnnotationsToEvents(
  "docs",
  { status: "complete", updated_at: at, started_at: at, updated_seq: 7, skip_reason: "s" },
  { createdAt: at }
);
console.log("D3.keys=" + evs.map((e) => e.key).join(","));

// D4 — inheritance must RE-DERIVE the heir seq, never carry the donor value.
// Donor and heir stream orders are deliberately different so a carried value is
// numerically distinguishable from a re-derived one.
const donor = "seq1665-d4donor";
const heir = "seq1665-d4heir";
S.markStep(donor, "research", "complete", { skip_reason: "r" });
S.markStep(donor, "workflow_init", "complete");
S.markStep(donor, "clarify_intent", "complete");
const d = S.readState(donor);
console.log("D4.donor_seq=" + JSON.stringify(d.steps.research.updated_seq));
A.applyInheritance(heir, "2026-02-01T00:00:00.000Z", d);
const h = S.readState(heir);
const lastSeq = {};
for (const e of h.events) if (e.kind === "step_status") lastSeq[e.step] = e.seq;
console.log("D4.heir_seq=" + JSON.stringify(h.steps.research.updated_seq));
console.log("D4.heir_stream_seq=" + JSON.stringify(lastSeq.research));
console.log("D4.leaked_annotations=" + h.events.filter((e) => e.kind === "step_annotation" && e.key === "updated_seq").length);
'

if require_js_ok "D: reserved-key probe"; then
    assert_js "D1 reserved key: status" D1.status "InvalidEventError"
    assert_js "D1 reserved key: updated_at" D1.updated_at "InvalidEventError"
    assert_js "D1 reserved key: started_at" D1.started_at "InvalidEventError"
    assert_js "D1 reserved key: updated_seq" D1.updated_seq "InvalidEventError"
    assert_js "D1 sanctioned annotation key still accepted (CPR-ORTH)" D1.allowed "no-throw"
    assert_js "D1 appendEvents refuses the reserved key end-to-end" D1.append "InvalidEventError"
    assert_js "D2 markStep extraFields cannot forge updated_seq" D2.updated_seq "1"
    assert_js "D2 markStep emitted only the real annotation" D2.ann_keys "skip_reason"
    assert_js "D2 sanctioned extraField still lands (CPR-ORTH)" D2.skip_reason '"keep"'
    assert_js "D3 v1 converter drops every structure key" D3.keys "skip_reason"
    assert_js "D4 donor seq (fixture precondition)" D4.donor_seq "1"
    assert_js "D4 heir re-derives its own seq" D4.heir_seq "3"
    assert_js "D4 heir projection agrees with the heir stream" D4.heir_stream_seq "3"
    assert_js "D4 no updated_seq annotation leaked into the heir" D4.leaked_annotations "0"
fi

finish

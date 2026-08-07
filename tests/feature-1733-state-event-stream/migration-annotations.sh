#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/migration-annotations.sh
# Tests: hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/state-io/projection.js
# Tags: workflow-state, event-stream, migration, annotations, property-test, scope:issue-specific, pwsh-not-required, TL2
#
# The v1->v2 converter must move step entry fields MECHANICALLY — never by enumerating
# key names — or the first field someone adds after this lands is silently destroyed.
# Case (f) is the load-bearing one: a single property check comparing
# projectState(migrate(v1)).steps against the original v1 steps catches every field the
# converter forgot, including ones this file does not name. The named-key matrix (a)-(e)
# exists so a failure says WHICH rule broke, not merely that something differs.
#
# TL3 gap (what this test does NOT catch):
# - real v1 files from earlier releases: fixtures are synthesised, so a field shape no
#   one anticipated is out of reach. The property check in (f) is the mitigation that
#   generalises beyond the fixture's key list.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="migann"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"
seed_v1() { (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" "$2") > "$WF/$1.json"; }

echo "== K0: all 9 real annotation keys survive as step_annotation events =="
if run_case "K0/nine-known-keys"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const KEYS = ["token", "wsid", "warnings_summary", "warnings_accepted_reason",
              "invalidate_reason", "skip_reason", "skip_verdict", "skip_judgment", "reset_reason"];
const st = S.readState(sid);
const seen = new Set(st.events.filter((e) => e.kind === "step_annotation").map((e) => e.key));
const missing = KEYS.filter((k) => !seen.has(k));
console.log("known_keys=" + KEYS.length + " missing_as_event=" + (missing.join(",") || "0"));
'
    assert_eq "K0/nine-known-keys" "known_keys=9 missing_as_event=0" "$NODE_OUT"
fi

echo "== K0b: STEP_ANNOTATION_KEYS is the documented 9-key table =="
if run_case "K0b/annotation-key-table"; then
    next_sid
    nodejs "$SID" '
const E = require("./hooks/workflow-state/state-io/events");
const WANT = ["invalidate_reason", "reset_reason", "skip_judgment", "skip_reason", "skip_verdict",
              "token", "warnings_accepted_reason", "warnings_summary", "wsid"];
const got = [...E.STEP_ANNOTATION_KEYS].sort();
console.log(JSON.stringify(got) === JSON.stringify(WANT) ? "MATCH" : "DIFFER got=" + JSON.stringify(got));
'
    assert_eq "K0b/annotation-key-table" "MATCH" "$NODE_OUT"
fi

echo "== K-a: pending + updated_at:null + skip_verdict is NOT dropped =="
if run_case "K-a/pending-with-verdict-kept"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const e = st.steps.review_security;
const statusEvents = st.events.filter((x) => x.kind === "step_status" && x.step === "review_security").length;
console.log("status=" + e.status +
            " verdict=" + (e.skip_verdict && e.skip_verdict.verdict) +
            " reason=" + (e.skip_verdict && e.skip_verdict.reason) +
            " status_events=" + statusEvents);
'
    # pending is the projection DEFAULT, so no step_status event is emitted for it —
    # but the annotation must still be there.
    assert_eq "K-a/pending-with-verdict-kept" \
        "status=pending verdict=skip reason=no security surface status_events=0" "$NODE_OUT"
fi

echo "== K-b: an unknown key (future_field) is converted like any other =="
if run_case "K-b/unknown-key-converted"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const ev = st.events.find((e) => e.kind === "step_annotation" && e.key === "future_field");
console.log("event=" + (ev ? ev.step + "/" + ev.value : "MISSING") +
            " projected=" + st.steps.review_tests.future_field);
'
    assert_eq "K-b/unknown-key-converted" \
        "event=review_tests/unknown-key-must-survive projected=unknown-key-must-survive" "$NODE_OUT"
fi

echo "== K-c: an inner recorded_at becomes the event at-value with provenance observed =="
if run_case "K-c/recorded-at-wins"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const verdictEv = st.events.find((e) => e.key === "skip_verdict");
const judgmentEv = st.events.find((e) => e.key === "skip_judgment");
console.log([
  "verdict_at=" + verdictEv.at,
  "verdict_provenance=" + verdictEv.provenance,
  "verdict_at_estimated=" + ("at_estimated" in verdictEv),
  "judgment_at=" + judgmentEv.at,
  "judgment_provenance=" + judgmentEv.provenance,
].join(" "));
'
    assert_eq "K-c/recorded-at-wins" \
        "verdict_at=2026-06-20T10:07:30.000Z verdict_provenance=observed verdict_at_estimated=false judgment_at=2026-06-20T10:09:00.000Z judgment_provenance=observed" \
        "$NODE_OUT"
fi

echo "== K-d: a null-valued v1 field is preserved as a value:null annotation =="
if run_case "K-d/null-value-preserved"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const ev = st.events.find((e) => e.kind === "step_annotation" && e.key === "invalidate_reason");
console.log("event_present=" + !!ev +
            " value=" + JSON.stringify(ev && ev.value) +
            " projected_key_absent=" + !("invalidate_reason" in st.steps.review_tests));
'
    assert_eq "K-d/null-value-preserved" "event_present=true value=null projected_key_absent=true" "$NODE_OUT"
fi

echo "== K-e: started_at is discarded everywhere (the retired #1640 field) =="
if run_case "K-e/started-at-discarded"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
S.readState(sid); S.persistMigratedState(sid);
const st = S.readState(sid);
console.log("in_file=" + /started_at/.test(raw()) +
            " in_projection=" + ("started_at" in st.steps.review_tests));
'
    assert_eq "K-e/started-at-discarded" "in_file=false in_projection=false" "$NODE_OUT"
fi

echo "== K-e2: a step_status event always precedes that step's annotations =="
if run_case "K-e2/status-before-annotations"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const bad = [];
for (const e of st.events.filter((x) => x.kind === "step_annotation")) {
  const st0 = st.events.find((x) => x.kind === "step_status" && x.step === e.step);
  if (st0 && st0.seq > e.seq) bad.push(e.step + "/" + e.key);
}
console.log(bad.length ? "BAD " + bad.join(",") : "OK");
'
    assert_eq "K-e2/status-before-annotations" "OK" "$NODE_OUT"
fi

echo "== K-f: PROPERTY — projectState(migrate(v1)).steps deep-equals the v1 steps =="
if run_case "K-f/property-round-trip"; then
    for preset in annotations ordering toplevel; do
        next_sid
        seed_v1 "$SID" "$preset"
        nodejs "$SID" "$PRE"'
const M = require("./hooks/workflow-state/state-io/migrations/v1-to-v2");
const PJ = require("./hooks/workflow-state/state-io/projection");
const C = require("./hooks/workflow-state/state-io/core");
const v1 = JSON.parse(raw());
// The expected value follows the invariant declared in the plan: the v1 steps minus
// `started_at` and minus empty pending entries (updated_at null AND no extra fields).
// projectState() ALWAYS populates every VALID_STEPS entry as a pending default (a
// long-standing pre-#1733 invariant, not new behaviour) — so `want` must seed the same
// defaults before overlaying the explicit v1 fixture steps, or the fixture-absent steps
// (present in `got` as pending defaults) make the comparison fail on key-set alone.
const want = {};
for (const step of C.VALID_STEPS) want[step] = { status: "pending", updated_at: null };
for (const [step, entry] of Object.entries(v1.steps || {})) {
  const extras = Object.keys(entry).filter((k) => !["status", "updated_at", "started_at"].includes(k));
  if (entry.updated_at == null && entry.status === "pending" && extras.length === 0) continue;
  const out = { status: entry.status, updated_at: entry.updated_at };
  for (const k of extras) if (entry[k] !== null) out[k] = entry[k];
  want[step] = out;
}
const got = PJ.projectState(M.migrateV1ToV2(JSON.parse(raw()))).steps;
const norm = (o) => JSON.stringify(Object.keys(o).sort().map((k) => [k, Object.keys(o[k]).sort().map((f) => [f, o[k][f]])]));
// updated_at for a backfilled entry becomes created_at, which the invariant allows:
// compare it separately from the rest of the entry.
for (const step of Object.keys(want)) {
  if (want[step].updated_at == null && got[step]) want[step].updated_at = got[step].updated_at;
}
console.log(norm(want) === norm(got) ? "EQUAL" : "DIFFER\nwant=" + norm(want) + "\ngot =" + norm(got));
'
        assert_eq "K-f/property-round-trip[$preset]" "EQUAL" "$NODE_OUT"
    done
fi

echo "== K-g: the annotation ordering rule is shared with session inheritance (CPR-E2C) =="
if run_case "K-g/shared-ordering-helper"; then
    next_sid
    nodejs "$SID" '
const M = require("./hooks/workflow-state/state-io/migrations/v1-to-v2");
// The plan requires ONE ordering function, reused by session-start. If inheritance
// grows its own copy the two will drift; assert the export exists and is stable.
const f = M.orderedAnnotationKeys;
if (typeof f !== "function") { console.log("MISSING-EXPORT"); process.exit(0); }
const a = f({ zeta: 1, token: 2, alpha: 3, wsid: 4 });
const b = f({ alpha: 3, wsid: 4, zeta: 1, token: 2 });
console.log(JSON.stringify(a) === JSON.stringify(b) ? "STABLE " + a.join(",") : "UNSTABLE");
'
    # Known keys first in STEP_ANNOTATION_KEYS order, then the rest alphabetically.
    assert_eq "K-g/shared-ordering-helper" "STABLE token,wsid,alpha,zeta" "$NODE_OUT"
fi

finish "migration-annotations"

#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/events-append.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/projection.js
# Tags: workflow-state, event-stream, append-only, mark-step, scope:issue-specific, pwsh-not-required, TL2
#
# A1: the defining property of #1733 — re-marking a step no longer overwrites the
# previous record. Every transition leaves its own event behind, so the interval
# between two passes over the same step is recoverable after the fact.
#
# TL3 gap (what this test does NOT catch):
# - the real PreToolUse/PostToolUse hook registration: markStep is called as a module
#   here, so a settings.json wiring mistake that stops workflow-mark from firing is invisible.
# - real elapsed wall-clock durations between two marks (all writes happen inside one
#   test run, so `at` deltas are milliseconds and cannot reveal a host clock defect).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="append"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== A1: re-marking the same step keeps both events =="
if run_case "A1/both-events-retained"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "in_progress");
const afterFirst = rd().events.filter((e) => e.kind === "step_status" && e.step === "run_tests");
sleep(5);
S.markStep(sid, "run_tests", "complete");
const all = rd().events.filter((e) => e.kind === "step_status" && e.step === "run_tests");
const statuses = all.map((e) => e.status).join(">");
const distinctAt = new Set(all.map((e) => e.at)).size;
console.log([
  "first=" + afterFirst.length,
  "second=" + all.length,
  "statuses=" + statuses,
  "distinct_at=" + distinctAt,
  "current=" + cur().steps.run_tests.status,
].join(" "));
'
    assert_eq "A1/both-events-retained" \
        "first=1 second=2 statuses=in_progress>complete distinct_at=2 current=complete" "$NODE_OUT"
fi

echo "== A2: the earlier event's fields are byte-identical after the later append =="
if run_case "A2/earlier-event-immutable"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "in_progress");
const before = JSON.stringify(rd().events);
sleep(5);
S.markStep(sid, "run_tests", "complete");
const after = JSON.stringify(rd().events.slice(0, JSON.parse(before).length));
console.log(before === after ? "IMMUTABLE" : "MUTATED\n" + before + "\n" + after);
'
    assert_eq "A2/earlier-event-immutable" "IMMUTABLE" "$NODE_OUT"
fi

echo "== A3: a backwards transition (complete -> pending -> complete) keeps all 3 events =="
if run_case "A3/backwards-transition"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete"); sleep(3);
S.markStep(sid, "run_tests", "pending");  sleep(3);
S.markStep(sid, "run_tests", "complete");
const all = rd().events.filter((e) => e.kind === "step_status" && e.step === "run_tests");
const monotonic = all.every((e, i) => i === 0 || all[i - 1].at <= e.at);
console.log("n=" + all.length + " seq_order=" + all.map((e) => e.seq).join(",") +
            " monotonic=" + monotonic + " current=" + cur().steps.run_tests.status);
'
    assert_eq "A3/backwards-transition" "n=3 seq_order=1,2,3 monotonic=true current=complete" "$NODE_OUT"
fi

echo "== A4: seq is 1-based and always equals index+1 =="
if run_case "A4/seq-contiguity"; then
    next_sid
    nodejs "$SID" "$PRE"'
for (let i = 0; i < 6; i++) S.markStep(sid, "run_tests", i % 2 ? "complete" : "in_progress");
const ev = rd().events;
const bad = ev.filter((e, i) => e.seq !== i + 1).map((e, i) => e.seq);
console.log("n=" + ev.length + " bad=" + (bad.length ? bad.join(",") : "0") + " first=" + ev[0].seq);
'
    assert_eq "A4/seq-contiguity" "n=6 bad=0 first=1" "$NODE_OUT"
fi

echo "== A5: extraFields become step_annotation events, not part of step_status =="
if run_case "A5/extrafields-split"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "research", "skipped", { skip_reason: "not needed" });
const ev = rd().events;
const st = ev.filter((e) => e.kind === "step_status");
const an = ev.filter((e) => e.kind === "step_annotation");
console.log("status_events=" + st.length +
            " annotation_events=" + an.length +
            " status_has_extra=" + ("skip_reason" in st[0]) +
            " ann=" + an[0].step + "/" + an[0].key + "/" + an[0].value +
            " projected=" + cur().steps.research.skip_reason);
'
    assert_eq "A5/extrafields-split" \
        "status_events=1 annotation_events=1 status_has_extra=false ann=research/skip_reason/not needed projected=not needed" \
        "$NODE_OUT"
fi

echo "== A6: every event carries the common field set =="
if run_case "A6/common-fields"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "research", "skipped", { skip_reason: "r" });
const P = require("./hooks/workflow-state/state-io/events").PROVENANCE_VALUES;
const bad = [];
for (const e of rd().events) {
  if (typeof e.seq !== "number") bad.push(e.kind + "/seq");
  if (!/^\d{4}-\d{2}-\d{2}T.*Z$/.test(e.at || "")) bad.push(e.kind + "/at");
  if (typeof e.kind !== "string" || !e.kind) bad.push("kind");
  if (!P.includes(e.provenance)) bad.push(e.kind + "/provenance=" + e.provenance);
  if (typeof e.origin !== "string" || !e.origin) bad.push(e.kind + "/origin");
}
console.log(bad.length ? "BAD " + bad.join(",") : "OK");
'
    assert_eq "A6/common-fields" "OK" "$NODE_OUT"
fi

echo "== A7: default provenance for a plain markStep is observed =="
if run_case "A7/default-provenance"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
const e = rd().events.find((x) => x.kind === "step_status");
console.log("provenance=" + e.provenance + " at_estimated=" + ("at_estimated" in e));
'
    assert_eq "A7/default-provenance" "provenance=observed at_estimated=false" "$NODE_OUT"
fi

echo "== A8: validateEvent rejects an unknown kind and a bad provenance =="
if run_case "A8/validate-event"; then
    next_sid
    nodejs "$SID" '
const E = require("./hooks/workflow-state/state-io/events");
const probe = (ev) => { try { E.validateEvent(ev); return "accepted"; } catch (e) { return "rejected"; } };
console.log([
  "unknown_kind=" + probe({ kind: "no_such_kind", provenance: "observed", origin: "t" }),
  "bad_provenance=" + probe({ kind: "step_status", step: "run_tests", status: "complete", provenance: "guessed", origin: "t" }),
  "missing_field=" + probe({ kind: "step_status", provenance: "observed", origin: "t" }),
  "good=" + probe({ kind: "step_status", step: "run_tests", status: "complete", provenance: "observed", origin: "t" }),
].join(" "));
'
    assert_eq "A8/validate-event" \
        "unknown_kind=rejected bad_provenance=rejected missing_field=rejected good=accepted" "$NODE_OUT"
fi

echo "== A9: an unknown annotation key is accepted (warn-only, never silently dropped) =="
if run_case "A9/unknown-annotation-key"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete", { future_field: "keepme" });
console.log("projected=" + cur().steps.run_tests.future_field +
            " events=" + rd().events.filter((e) => e.key === "future_field").length);
'
    assert_eq "A9/unknown-annotation-key" "projected=keepme events=1" "$NODE_OUT"
fi

finish "events-append"

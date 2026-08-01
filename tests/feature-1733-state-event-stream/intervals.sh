#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/intervals.sh
# Tests: hooks/workflow-state/state-io/intervals.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, event-stream, intervals, measurement, scope:issue-specific, pwsh-not-required, TL2
#
# The acceptance criterion of #1733 is "interval durations are computable after the
# fact". computeIntervals is that capability. The strongest single assertion is a
# CLOSURE property: the interval durations must tile the whole session with no gap and
# no overlap, i.e. their sum equals created_at -> terminal `at`. A renderer that
# silently skipped an event would break the sum even if every individual row looked fine.
#
# TL3 gap (what this test does NOT catch):
# - real wall-clock spans: every event here is written inside one test run, so a
#   host clock/timezone defect that only shows up over minutes is invisible.
# - hook registration: markStep is called as a module, not via a fired hook.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="iv"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== I1: intervals tile the session with no gaps (sum == created_at -> terminal) =="
if run_case "I1/closure-property"; then
    next_sid
    nodejs "$SID" "$PRE$APPROVE_GATED_JS"'
const IV = require("./hooks/workflow-state/state-io/intervals");
for (const step of S.VALID_STEPS) { S.markStep(sid, step, "complete"); sleep(2); }
const st = rd();
const rows = IV.computeIntervals(st);
const sum = rows.reduce((a, r) => a + (r.duration_ms || 0), 0);
const terminal = st.events.filter((e) => e.kind === "step_status" && e.step === "final_report").pop();
const span = Date.parse(terminal.at) - Date.parse(st.created_at);
const firstStart = rows[0] && rows[0].from_at;
console.log([
  "rows=" + (rows.length === st.events.length),
  "first_from_created_at=" + (firstStart === st.created_at),
  "sum_equals_span=" + (sum === span),
  "no_gaps=" + rows.every((r, i) => i === 0 || r.from_at === rows[i - 1].to_at),
].join(" "));
'
    assert_eq "I1/closure-property" \
        "rows=true first_from_created_at=true sum_equals_span=true no_gaps=true" "$NODE_OUT"
fi

echo "== I2: adjacent rows reference contiguous seq values =="
if run_case "I2/seq-contiguity"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
for (let i = 0; i < 5; i++) { S.markStep(sid, "run_tests", i % 2 ? "complete" : "in_progress"); sleep(2); }
const rows = IV.computeIntervals(rd());
const bad = rows.filter((r, i) => r.to_seq !== i + 1 || (i > 0 && r.from_seq !== i));
console.log("rows=" + rows.length + " bad=" + bad.length + " first_from_seq=" + rows[0].from_seq);
'
    # from_seq 0 is the synthetic created_at origin (no event owns it).
    assert_eq "I2/seq-contiguity" "rows=5 bad=0 first_from_seq=0" "$NODE_OUT"
fi

echo "== I3: every row carries a non-negative duration and its source event =="
if run_case "I3/row-shape"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
S.markStep(sid, "run_tests", "in_progress"); sleep(3);
S.markStep(sid, "run_tests", "complete");
const rows = IV.computeIntervals(rd());
const bad = [];
for (const r of rows) {
  if (typeof r.duration_ms !== "number" || r.duration_ms < 0) bad.push("duration=" + r.duration_ms);
  if (!r.event || r.event.seq !== r.to_seq) bad.push("event-mismatch@" + r.to_seq);
  if (!r.from_at || !r.to_at) bad.push("missing-at@" + r.to_seq);
}
console.log(bad.length ? "BAD " + bad.join(",") : "OK");
'
    assert_eq "I3/row-shape" "OK" "$NODE_OUT"
fi

echo "== I4: a backwards at value yields duration_ms:null + out_of_order, keeping BOTH events =="
if run_case "I4/out-of-order"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
S.markStep(sid, "run_tests", "in_progress");
S.markStep(sid, "run_tests", "complete");
// Simulate a clock that went backwards between two appends. Rewriting the file
// directly is the only way to produce it: appendEvents stamps `at` from Date.now().
const st = rd();
st.events[st.events.length - 1].at = "2000-01-01T00:00:00.000Z";
wraw(st);
const rows = IV.computeIntervals(rd());
const last = rows[rows.length - 1];
console.log("events=" + st.events.length +
            " rows=" + rows.length +
            " duration=" + last.duration_ms +
            " out_of_order=" + last.out_of_order);
'
    assert_eq "I4/out-of-order" "events=2 rows=2 duration=null out_of_order=true" "$NODE_OUT"
fi

echo "== I5: backfilled events are flagged estimated so they can be excluded from stats =="
if run_case "I5/estimated-flag"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
S.markStep(sid, "run_tests", "complete");
const st = rd();
st.events[st.events.length - 1].provenance = "backfilled";
st.events[st.events.length - 1].at_estimated = true;
wraw(st);
const rows = IV.computeIntervals(rd());
const last = rows[rows.length - 1];
console.log("estimated=" + last.estimated + " has_duration=" + (typeof last.duration_ms === "number"));
'
    assert_eq "I5/estimated-flag" "estimated=true has_duration=true" "$NODE_OUT"
fi

echo "== I6: an empty event stream yields an empty interval list (no throw) =="
if run_case "I6/empty-stream"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
const fresh = S.createInitialState(sid);
let verdict;
try { verdict = "rows=" + IV.computeIntervals(fresh).length; } catch (e) { verdict = "THREW:" + e.message; }
console.log(verdict);
'
    assert_eq "I6/empty-stream" "rows=0" "$NODE_OUT"
fi

echo "== I7: the terminal boundary is the final_report step_status event =="
if run_case "I7/terminal-boundary"; then
    next_sid
    nodejs "$SID" "$PRE"'
const IV = require("./hooks/workflow-state/state-io/intervals");
S.markStep(sid, "run_tests", "complete"); sleep(2);
const beforeTerminal = IV.computeIntervals(rd());
S.markStep(sid, "final_report", "complete");
const afterTerminal = IV.computeIntervals(rd());
const last = afterTerminal[afterTerminal.length - 1];
console.log("grew=" + (afterTerminal.length === beforeTerminal.length + 1) +
            " terminal_step=" + last.event.step +
            " terminal_kind=" + last.event.kind);
'
    assert_eq "I7/terminal-boundary" "grew=true terminal_step=final_report terminal_kind=step_status" "$NODE_OUT"
fi

# Builds a state object in memory with hand-written events. computeIntervals takes a
# state, so the boundary values below (equal, unparseable, post-terminal) can be posed
# directly instead of being coaxed out of a real writer that would refuse to produce them.
IV_FIXTURE_JS='const IV = require("./hooks/workflow-state/state-io/intervals");
const mkState = (ats) => ({
  version: 2,
  session_id: sid,
  created_at: "2026-06-20T09:00:00.000Z",
  events: ats.map((spec, i) => Object.assign({
    seq: i + 1,
    at: typeof spec === "string" ? spec : spec.at,
    kind: "step_status",
    step: "run_tests",
    status: "complete",
    provenance: "observed",
    origin: "fixture",
  }, typeof spec === "string" ? {} : spec)),
  current: { steps: {} },
});
const run = (ats) => { try { return { rows: IV.computeIntervals(mkState(ats)) }; } catch (e) { return { threw: (e && e.name) || "Error" }; } };
'

echo "== I8: two events at the SAME instant give a zero-length interval, not a crash =="
if run_case "I8/equal-timestamps"; then
    next_sid
    nodejs "$SID" "$PRE$IV_FIXTURE_JS"'
// Two hooks firing inside the same millisecond is ordinary on a fast host, and an
// appendEvents batch stamps its whole batch with one `at` by design — so equal
// timestamps are the common case, not a pathological one.
const r = run(["2026-06-20T09:00:10.000Z", "2026-06-20T09:00:10.000Z", "2026-06-20T09:00:12.000Z"]);
if (r.threw) { console.log("THREW:" + r.threw); }
else {
  const d = r.rows.map((x) => x.duration_ms);
  console.log([
    "rows=" + r.rows.length,
    "durations=" + JSON.stringify(d),
    "zero_not_null=" + (d[1] === 0),
    "no_out_of_order=" + r.rows.every((x) => x.out_of_order !== true),
  ].join(" "));
}
'
    assert_eq "I8/equal-timestamps" \
        "rows=3 durations=[10000,0,2000] zero_not_null=true no_out_of_order=true" "$NODE_OUT"
fi

echo "== I9: an unparseable timestamp yields null, never NaN =="
if run_case "I9/unparseable-timestamp"; then
    next_sid
    nodejs "$SID" "$PRE$IV_FIXTURE_JS"'
// NaN propagates: it survives JSON.stringify as null in some renderers and as the
// literal NaN in others, and any comparison against it is false — so a single bad `at`
// silently poisons every total downstream. It must be contained at the row that has it.
const r = run(["2026-06-20T09:00:10.000Z", "not-a-timestamp", "2026-06-20T09:00:20.000Z"]);
if (r.threw) { console.log("THREW:" + r.threw); }
else {
  const d = r.rows.map((x) => x.duration_ms);
  console.log([
    "rows=" + r.rows.length,
    "any_nan=" + d.some((x) => typeof x === "number" && Number.isNaN(x)),
    "bad_row_null=" + (d[1] === null),
    "next_row_null=" + (d[2] === null),
    "json_safe=" + (JSON.stringify(d).indexOf("NaN") === -1),
  ].join(" "));
}
'
    assert_eq "I9/unparseable-timestamp" \
        "rows=3 any_nan=false bad_row_null=true next_row_null=true json_safe=true" "$NODE_OUT"
fi

echo "== I10: with several final_report events, the FIRST one closes the calculation =="
if run_case "I10/multiple-terminals"; then
    next_sid
    nodejs "$SID" "$PRE$IV_FIXTURE_JS"'
// A reset after the report, or a re-run of the final step, produces a second terminal.
// Which one closes the session has to be FIXED rather than left to the implementation:
// taking the last would make the measured duration grow every time someone re-marks the
// step, and the number would drift with no visible cause.
const ats = [
  { at: "2026-06-20T09:00:10.000Z", step: "run_tests" },
  { at: "2026-06-20T09:00:20.000Z", step: "final_report" },
  { at: "2026-06-20T09:00:30.000Z", step: "final_report" },
];
const r = run(ats);
if (r.threw) { console.log("THREW:" + r.threw); }
else {
  const total = r.rows.reduce((a, x) => a + (x.duration_ms || 0), 0);
  const last = r.rows[r.rows.length - 1];
  console.log([
    "rows=" + r.rows.length,
    "total=" + total,
    "closing_seq=" + last.to_seq,
    "closing_step=" + last.event.step,
  ].join(" "));
}
'
    # created_at 09:00:00 -> first terminal 09:00:20 = 20000ms. The events after the
    # terminal are not rows at all: the session is closed.
    assert_eq "I10/multiple-terminals" "rows=2 total=20000 closing_seq=2 closing_step=final_report" "$NODE_OUT"
fi

echo "== I11: events appended AFTER the terminal do not extend the last interval =="
if run_case "I11/post-terminal-events"; then
    next_sid
    nodejs "$SID" "$PRE$IV_FIXTURE_JS"'
const upto = [
  { at: "2026-06-20T09:00:10.000Z", step: "run_tests" },
  { at: "2026-06-20T09:00:20.000Z", step: "final_report" },
];
const before = run(upto);
// A worktree exit or a docs mark landing after the report is normal. Absorbing it into
// the final interval would inflate the reported session length by the length of the
// cleanup that happened afterwards.
const after = run(upto.concat([{ at: "2026-06-20T09:05:00.000Z", step: "docs" }]));
if (before.threw || after.threw) { console.log("THREW:" + (before.threw || after.threw)); }
else {
  const strip = (rows) => JSON.stringify(rows.map((r) => [r.from_seq, r.to_seq, r.duration_ms]));
  console.log([
    "rows_before=" + before.rows.length,
    "rows_after=" + after.rows.length,
    "identical=" + (strip(before.rows) === strip(after.rows)),
  ].join(" "));
}
'
    assert_eq "I11/post-terminal-events" "rows_before=2 rows_after=2 identical=true" "$NODE_OUT"
fi

echo "== I12: an event BEFORE created_at is out_of_order, not a negative duration =="
if run_case "I12/before-origin"; then
    next_sid
    nodejs "$SID" "$PRE$IV_FIXTURE_JS"'
// Same class as the backwards-transition case, at the other boundary: the origin. A
// clock adjustment between session start and the first hook produces exactly this.
const r = run(["2026-06-20T08:59:00.000Z", "2026-06-20T09:00:10.000Z"]);
if (r.threw) { console.log("THREW:" + r.threw); }
else {
  console.log([
    "rows=" + r.rows.length,
    "first_duration=" + JSON.stringify(r.rows[0].duration_ms),
    "first_flagged=" + (r.rows[0].out_of_order === true),
    "no_negative=" + r.rows.every((x) => x.duration_ms === null || x.duration_ms >= 0),
  ].join(" "));
}
'
    assert_eq "I12/before-origin" "rows=2 first_duration=null first_flagged=true no_negative=true" "$NODE_OUT"
fi

finish "intervals"

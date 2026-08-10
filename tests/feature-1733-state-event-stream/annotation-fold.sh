#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/annotation-fold.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/review-tests.js, hooks/workflow-state/state-io/skip-verdict.js, hooks/workflow-state/skip-signal-resolver.js
# Tags: workflow-state, event-stream, annotations, review-tests, skip-verdict, last-write-wins, scope:issue-specific, pwsh-not-required, TL2
#
# Before #1733, markStep REPLACED the whole step entry, so review-tests.js,
# skip-verdict.js and skip-signal-resolver.js all carried sibling fields by hand to
# avoid destroying them. Splitting annotations into their own events removes that
# hazard, but introduces the opposite one: a field that should be gone can now linger.
# Both directions are covered here — merge must keep siblings, and deletion must be an
# EXPLICIT event (value:null or step_annotations_cleared), never implicit.
#
# TL3 gap (what this test does NOT catch):
# - the /review-tests skill's own orchestration: these cases call the recorder modules
#   directly, so a SKILL.md step that stops invoking markReviewTestsComplete is invisible.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

CASE_TAG="ann"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== N1: last-write-wins per (step, key), independently across keys =="
if run_case "N1/last-write-wins"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "review_tests", "complete", { token: "t1", wsid: "w1" });
S.markStep(sid, "review_tests", "complete", { token: "t2" });
const e = cur().steps.review_tests;
console.log("token=" + e.token + " wsid=" + e.wsid +
            " token_events=" + rd().events.filter((x) => x.key === "token").length);
'
    assert_eq "N1/last-write-wins" "token=t2 wsid=w1 token_events=2" "$NODE_OUT"
fi

echo "== N2: annotations are per-step — a same-named key on another step is untouched =="
if run_case "N2/per-step-isolation"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "research", "skipped", { skip_reason: "r-research" });
S.markStep(sid, "cleanup", "skipped", { skip_reason: "r-cleanup" });
S.markStep(sid, "research", "skipped", { skip_reason: "r-research-2" });
const c = cur().steps;
console.log("research=" + c.research.skip_reason + " cleanup=" + c.cleanup.skip_reason);
'
    assert_eq "N2/per-step-isolation" "research=r-research-2 cleanup=r-cleanup" "$NODE_OUT"
fi

echo "== N3: value:null deletes the key from the projection but stays in the stream =="
if run_case "N3/null-deletes"; then
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
S.markStep(sid, "review_tests", "complete", { token: "t1", wsid: "w1" });
E.appendEvents(sid, [{ kind: "step_annotation", step: "review_tests", key: "token", value: null,
                       provenance: "observed", origin: "test" }]);
const e = cur().steps.review_tests;
const kept = rd().events.filter((x) => x.key === "token").length;
console.log("has_token=" + ("token" in e) + " wsid=" + e.wsid + " token_events_in_stream=" + kept);
'
    assert_eq "N3/null-deletes" "has_token=false wsid=w1 token_events_in_stream=2" "$NODE_OUT"
fi

echo "== N4: step_annotations_cleared drops all prior annotations, keeps status + causal axis =="
if run_case "N4/annotations-cleared"; then
    # The clear branch REBUILDS the entry from scratch rather than deleting keys, so every
    # piece of projection metadata has to be re-listed there by hand. #1665 adds a third one
    # (updated_seq, the causal-order axis the write_code resume cascade compares against) —
    # dropping it would silently erase that axis on every annotation clear, WORKFLOW_RESET_FROM
    # included. The key set is compared strictly so an omission cannot pass, and the value is
    # compared to the pre-clear reading so "preserved" means preserved, not "re-defaulted to
    # null". seq_finite_before pins that the pre-clear value was a real number, otherwise
    # undefined === undefined would false-green the preservation check.
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
S.markStep(sid, "review_tests", "complete", { token: "t1", wsid: "w1", warnings_summary: "2 findings" });
const before = cur().steps.review_tests.updated_seq;
E.appendEvents(sid, [{ kind: "step_annotations_cleared", step: "review_tests",
                       provenance: "declared", origin: "test" }]);
const e = cur().steps.review_tests;
console.log("keys=" + Object.keys(e).sort().join(",") + " status=" + e.status +
            " seq_finite_before=" + Number.isFinite(before) +
            " seq_preserved=" + (e.updated_seq === before));
'
    assert_eq "N4/annotations-cleared" \
        "keys=status,updated_at,updated_seq status=complete seq_finite_before=true seq_preserved=true" \
        "$NODE_OUT"
fi

echo "== N5: annotations after a clear are kept (the clear is not sticky) =="
if run_case "N5/clear-not-sticky"; then
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
S.markStep(sid, "review_tests", "complete", { token: "t1" });
E.appendEvents(sid, [{ kind: "step_annotations_cleared", step: "review_tests", provenance: "declared", origin: "test" }]);
S.markStep(sid, "review_tests", "complete", { token: "t2" });
console.log("token=" + cur().steps.review_tests.token);
'
    assert_eq "N5/clear-not-sticky" "token=t2" "$NODE_OUT"
fi

echo "== N6: clearReviewTestsWarnings keeps token/wsid (the carry-by-hand hazard) =="
if run_case "N6/clear-warnings-keeps-fingerprint"; then
    next_sid
    nodejs "$SID" "$PRE"'
const RT = require("./hooks/workflow-state/state-io/review-tests");
RT.markReviewTestsComplete(sid, "tok-1", { wsid: "wsid-1", warnings_summary: "2 advisory findings" });
const before = cur().steps.review_tests;
RT.clearReviewTestsWarnings(sid);
const after = cur().steps.review_tests;
console.log("before_warn=" + (before.warnings_summary || "(none)") +
            " after_warn=" + (after.warnings_summary || "(none)") +
            " token=" + after.token + " wsid=" + after.wsid + " status=" + after.status);
'
    assert_eq "N6/clear-warnings-keeps-fingerprint" \
        "before_warn=2 advisory findings after_warn=(none) token=tok-1 wsid=wsid-1 status=complete" "$NODE_OUT"
fi

echo "== N7: clearReviewTestsWarnings with nothing to clear appends no annotation (idempotent) =="
if run_case "N7/clear-warnings-noop"; then
    next_sid
    nodejs "$SID" "$PRE"'
const RT = require("./hooks/workflow-state/state-io/review-tests");
RT.markReviewTestsComplete(sid, "tok-1", { wsid: "wsid-1" });
const n0 = rd().events.length;
RT.clearReviewTestsWarnings(sid);
const n1 = rd().events.length;
RT.clearReviewTestsWarnings(sid);
const n2 = rd().events.length;
console.log("grew_first=" + (n1 - n0) + " grew_second=" + (n2 - n1) + " token=" + cur().steps.review_tests.token);
'
    assert_eq "N7/clear-warnings-noop" "grew_first=0 grew_second=0 token=tok-1" "$NODE_OUT"
fi

echo "== N8: invalidateReviewTests explicitly nulls the fingerprint and warning keys =="
if run_case "N8/invalidate-explicit-nulls"; then
    next_sid
    nodejs "$SID" "$PRE"'
const RT = require("./hooks/workflow-state/state-io/review-tests");
RT.markReviewTestsComplete(sid, "tok-1", { wsid: "wsid-1", warnings_summary: "2 findings", warnings_accepted_reason: "ok" });
RT.invalidateReviewTests(sid, "tests re-edited");
const e = cur().steps.review_tests;
const gone = ["token", "wsid", "warnings_summary", "warnings_accepted_reason"].filter((k) => k in e);
console.log("still_present=" + (gone.join(",") || "0") +
            " invalidate_reason=" + e.invalidate_reason + " status=" + e.status);
'
    assert_eq "N8/invalidate-explicit-nulls" \
        "still_present=0 invalidate_reason=tests re-edited status=pending" "$NODE_OUT"
fi

echo "== N9: recordSkipVerdict lands as an annotation and readSkipVerdict round-trips it =="
if run_case "N9/skip-verdict-roundtrip"; then
    next_sid
    nodejs "$SID" "$PRE"'
const SV = require("./hooks/workflow-state/state-io/skip-verdict");
// Real contract: target is outline|detail only, verdict is pending|confirm|veto.
SV.recordSkipVerdict(sid, "detail", "pending", "skip-verifier");
const back = SV.readSkipVerdict(sid, "detail");
const e = cur().steps.detail;
console.log("verdict=" + (back && back.verdict) + " source=" + (back && back.source) +
            " status_untouched=" + e.status +
            " annotation_events=" + rd().events.filter((x) => x.key === "skip_verdict").length);
'
    assert_eq "N9/skip-verdict-roundtrip" \
        "verdict=pending source=skip-verifier status_untouched=pending annotation_events=1" "$NODE_OUT"
fi

echo "== N9b: an out-of-domain recordSkipVerdict target is still a no-op =="
if run_case "N9b/skip-verdict-domain"; then
    next_sid
    nodejs "$SID" "$PRE"'
const SV = require("./hooks/workflow-state/state-io/skip-verdict");
S.markStep(sid, "workflow_init", "complete");
const n0 = rd().events.length;
SV.recordSkipVerdict(sid, "review_security", "pending", "skip-verifier");
SV.recordSkipVerdict(sid, "detail", "not-a-verdict", "skip-verifier");
console.log("appended=" + (rd().events.length - n0) +
            " review_security_verdict=" + JSON.stringify(SV.readSkipVerdict(sid, "review_security")));
'
    assert_eq "N9b/skip-verdict-domain" "appended=0 review_security_verdict=null" "$NODE_OUT"
fi

echo "== N10: recordSkipJudgment does not clobber the step status (no read-back needed) =="
if run_case "N10/skip-judgment-preserves-status"; then
    next_sid
    nodejs "$SID" "$PRE$APPROVE_GATED_JS"'
const R = require("./hooks/workflow-state/skip-signal-resolver");
S.markStep(sid, "detail", "complete");
R.recordSkipJudgment(sid, "detail", { c1: true, c2: true }, "test-source");
const e = cur().steps.detail;
const j = e.skip_judgment || {};
console.log("status=" + e.status + " all_conditions_met=" + j.all_conditions_met +
            " source=" + j.judgment_source);
'
    # The pre-#1733 implementation had to re-read the current status and pass it back
    # through markStep to avoid resetting it; the annotation event makes that unnecessary,
    # but the OBSERVABLE contract must not change.
    assert_eq "N10/skip-judgment-preserves-status" \
        "status=complete all_conditions_met=true source=test-source" "$NODE_OUT"
fi

echo "== N11: an object-valued annotation survives verbatim (inner recorded_at intact) =="
if run_case "N11/object-value-verbatim"; then
    next_sid
    nodejs "$SID" "$PRE"'
const payload = { verdict: "skip", reason: "r", recorded_at: "2026-06-20T10:07:30.000Z", nested: { a: [1, 2] } };
S.markStep(sid, "review_security", "pending", { skip_verdict: payload });
const got = cur().steps.review_security.skip_verdict;
console.log(JSON.stringify(got) === JSON.stringify(payload) ? "VERBATIM" : "ALTERED " + JSON.stringify(got));
'
    assert_eq "N11/object-value-verbatim" "VERBATIM" "$NODE_OUT"
fi

finish "annotation-fold"

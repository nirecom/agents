"use strict";
// #2961 in-process cases for the paths that get no readinessFor from the caller:
// presentedArtifacts* (hooks/lib/confirm-continuation.js) fall back to the same stageReadiness built
// from gateFor, and recordUndecidable (hooks/stop-confirm-plan-guard/settle.js) neither records a
// receipt nor reports as unrecorded ("unwritten") a stage that is not presentable. Each case pairs an
// unsettled stage (not-ready) with a settled control, so a fixture that cannot present at all fails.
// Called from ../feature-2961-plan-presentation-turn-stop.js, which owns the case markers.
const assert = require("node:assert/strict");
const C = require("./common");

const { R, show } = C;
const CC = () => C.mod("hooks/lib/confirm-continuation");
const SETTLE = () => C.mod("hooks/stop-confirm-plan-guard/settle");

// probesOf(s) -> {gateFor, linkFor} with no readinessFor: ON, and the link the session's urlLine shows.
function probesOf(s) {
  const url = s.urlLine.split(" ")[1];
  return { gateFor: () => "ON", linkFor: (p) => ({ url, path: p }) };
}
const closing = (s) => "The outline is written.\n\n" + s.urlLine;
const stagesOf = (list) => list.map((p) => p.stage);

// presentedArtifactsOfText / presentedArtifacts without readinessFor: not-ready is not pushed.
function presentedFallback() {
  const ctl = C.at("outline");
  const got = CC().presentedArtifactsOfText(Object.assign({ sid: ctl.sid, lastText: closing(ctl), stages: ["outline"] }, probesOf(ctl)));
  assert.deepEqual(stagesOf(got), ["outline"], `fixture: the settled stage is presented ${show(got)}`);
  const open = C.at("outline", { audit: false });
  const none = CC().presentedArtifactsOfText(Object.assign({ sid: open.sid, lastText: closing(open), stages: ["outline"] }, probesOf(open)));
  assert.deepEqual(stagesOf(none), [], `unsettled, no readinessFor: not presented ${show(none)}`);
  const anchor = { uuid: "a-anchor", type: "assistant", message: { role: "assistant", content: [{ type: "text", text: closing(open) }] } };
  const tail = { lastTextEntry: anchor, lastAssistantEntry: anchor, lastTextBlock: closing(open), entries: [anchor] };
  const viaTail = CC().presentedArtifacts(Object.assign({ sid: open.sid, tail }, probesOf(open)));
  assert.deepEqual(stagesOf(viaTail), [], `presentedArtifacts, unsettled, no readinessFor: not presented ${show(viaTail)}`);
}

// recordUndecidable with caller probes lacking readinessFor: the unsettled stage gets no receipt and
// is not reported as unrecorded; the settled control is recorded.
function undecidableUnwritten() {
  const run = (s) => SETTLE().recordUndecidable({
    sid: s.sid, input: { last_assistant_message: closing(s) }, tail: null,
    markers: [{ suffix: "outline", absPath: s.plan }], deadline: Date.now() + 60000, active: false, probes: probesOf(s),
  });
  const ctl = C.at("outline");
  const a = run(ctl);
  assert.deepEqual(stagesOf(a.written), ["outline"], `fixture: the settled stage is recorded ${show(a)}`);
  assert.ok(R.receiptExists(ctl.sid, "outline"), "fixture: the settled stage's receipt");
  const open = C.at("outline", { audit: false });
  const b = run(open);
  assert.deepEqual(stagesOf(b.written), [], `unsettled: nothing recorded ${show(b)}`);
  assert.ok(!b.unrecorded.includes("outline"), `unsettled: not reported unrecorded (unwritten filter) ${show(b)}`);
  assert.ok(!R.receiptExists(open.sid, "outline"), "unsettled: no receipt");
}

module.exports = { presentedFallback, undecidableUnwritten };

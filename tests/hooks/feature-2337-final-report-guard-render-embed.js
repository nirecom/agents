"use strict";
// Tests: hooks/stop-final-report-guard.js, hooks/stop-final-report-guard/render-embed.js, hooks/stop-final-report-guard/exits.js
// Tags: feature-2337, stop-guard, final-report, render-embed, lane-a, scope:issue-specific, TL2, pwsh-not-required, feature-1192, lane-b, workflow-off, yield, exit-hatch
// #2337: the renderer's stdout stayed in a tool result, so the Final Report heading never reached
// the assistant text and lane A blocked with only "run /session-close". Lane A's no-heading block
// now carries the rendered Final Report and the shared exit-hatch text; when the renderer fails,
// the guard still blocks, just without the embed (fail-open on the embed, not on the block).
// #1192: the workflow-off marker and the yield gate run once at the top of lane A, so every lane-A
// block yields to them, and lanes A and B name the same exits through EXIT_HATCH_TEXT.
// TL3 gap: a live model re-emitting the embed verbatim; a real Stop event with a sentinel-set marker.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");
const G = require("../lib/final-report-guard-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f2337-");
const TRANSCRIPTS = path.join(SB, "transcripts");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

caseBegin("fixture-renderer-renders-the-report", "hooks/stop-final-report-guard.js");
test("fixture-renderer-renders-the-report", () => {
  const sid = "r-fixture";
  G.writeEnv(sid);
  const r = G.runRenderer(sid, SB);
  assert.strictEqual(r.rc, 0, r.err);
  assert.ok(r.out.includes(`## Final Report — ${sid}`), r.out.slice(0, 200));
});
caseEnd();

caseBegin("render-embed-module-returns-the-renderer-output", "hooks/stop-final-report-guard/render-embed.js");
test("render-embed-module-returns-the-renderer-output", () => {
  const sid = "r-module";
  G.writeEnv(sid);
  const renderFinalReportForReason = F.need("hooks/stop-final-report-guard/render-embed.js", "renderFinalReportForReason");
  assert.strictEqual(renderFinalReportForReason(sid), G.runRenderer(sid, SB).out);
  assert.strictEqual(renderFinalReportForReason("r-no-env-file"), null);
});
caseEnd();

caseBegin("no-heading-block-embeds-rendered-report-and-exit-hatch", "hooks/stop-final-report-guard.js");
test("no-heading-block-embeds-rendered-report-and-exit-hatch", () => {
  const sid = "r-embed";
  G.writeEnv(sid);
  const rendered = G.runRenderer(sid, SB).out;
  assert.ok(rendered.trim(), "fixture: the renderer produced a report");
  const r = G.runGuard(sid, G.writeTranscript(TRANSCRIPTS, sid, "Session closed; see the tool output above."), SB);
  assert.strictEqual(r.rc, 2, `stdout: ${r.out}`);
  assert.strictEqual(r.decision, "block");
  assert.ok(r.reason.includes(rendered.trim()), `the reason must embed the rendered report:\n${r.reason}`);
  assert.ok(r.reason.includes(G.exitHatchText()), "the reason must name the shared exits");
});
caseEnd();

caseBegin("no-heading-block-survives-renderer-failure", "hooks/stop-final-report-guard.js");
test("no-heading-block-survives-renderer-failure", () => {
  const sid = "r-broken";
  G.writeEnv(sid);
  G.writeControl(sid, "issue-close-outcome.json", { issues: [null] });
  assert.notStrictEqual(G.runRenderer(sid, SB).rc, 0, "fixture: the renderer must fail here");
  const r = G.runGuard(sid, G.writeTranscript(TRANSCRIPTS, sid, "Done."), SB);
  assert.strictEqual(r.rc, 2, `stdout: ${r.out}`);
  assert.strictEqual(r.decision, "block");
  assert.ok(!r.reason.includes("### Closed Issues"), "no partial report is embedded");
  assert.ok(r.reason.includes(G.exitHatchText()), "the exits are still named");
});
caseEnd();

// The three lane-A block shapes: no heading, a missing heading, an unsubstituted token.
const SHAPES = {
  "no-heading": () => "All done here.",
  "missing-heading": (sid) => G.reportText(sid, { drop: [3] }),
  "leftover-token": (sid) => G.reportText(sid, { extra: "\n<PR_NUMBER>" }),
};

function laneA(sid, shape, exitHatch) {
  G.writeEnv(sid);
  if (exitHatch) exitHatch(sid);
  return G.runGuard(sid, G.writeTranscript(TRANSCRIPTS, sid, SHAPES[shape](sid)), SB);
}

caseBegin("fixture-lane-a-blocks-every-shape-without-an-exit", "hooks/stop-final-report-guard.js");
test("fixture-lane-a-blocks-every-shape-without-an-exit", () => {
  for (const shape of Object.keys(SHAPES)) {
    const r = laneA(`x-none-${shape}`, shape, null);
    assert.strictEqual(r.rc, 2, `${shape}: ${r.out}`);
  }
});
caseEnd();

caseBegin("workflow-off-exits-every-lane-a-block", "hooks/stop-final-report-guard.js");
test("workflow-off-exits-every-lane-a-block", () => {
  for (const shape of Object.keys(SHAPES)) {
    const r = laneA(`x-off-${shape}`, shape, G.writeWorkflowOff);
    assert.strictEqual(r.rc, 0, `${shape} must not block under workflow-off: ${r.out}`);
  }
});
caseEnd();

caseBegin("yield-exits-every-lane-a-block", "hooks/stop-final-report-guard.js");
test("yield-exits-every-lane-a-block", () => {
  for (const shape of Object.keys(SHAPES)) {
    const r = laneA(`x-yield-${shape}`, shape, G.writeYield);
    assert.strictEqual(r.rc, 0, `${shape} must not block after a yield: ${r.out}`);
  }
});
caseEnd();

caseBegin("exits-module-decides-off-then-yield", "hooks/stop-final-report-guard/exits.js");
test("exits-module-decides-off-then-yield", () => {
  const shouldYieldOrBypass = F.need("hooks/stop-final-report-guard/exits.js", "shouldYieldOrBypass");
  assert.strictEqual(shouldYieldOrBypass("x-mod-none").exit, false);
  G.writeWorkflowOff("x-mod-off");
  assert.strictEqual(shouldYieldOrBypass("x-mod-off").exit, true);
  G.writeYield("x-mod-yield");
  assert.strictEqual(shouldYieldOrBypass("x-mod-yield").exit, true);
  assert.strictEqual(typeof G.exitHatchText(), "string");
  assert.ok(G.exitHatchText().trim().length > 0);
});
caseEnd();

caseBegin("exits-module-reasons-and-order", "hooks/stop-final-report-guard/exits.js");
test("exits-module-reasons-and-order", () => {
  const shouldYieldOrBypass = F.need("hooks/stop-final-report-guard/exits.js", "shouldYieldOrBypass");
  assert.deepStrictEqual(shouldYieldOrBypass("x-ord-none"), { exit: false, reason: null });
  G.writeWorkflowOff("x-ord-off");
  assert.deepStrictEqual(shouldYieldOrBypass("x-ord-off"), { exit: true, reason: "workflow-off" });
  G.writeYield("x-ord-yield");
  assert.deepStrictEqual(shouldYieldOrBypass("x-ord-yield"), { exit: true, reason: "session-close-yield" });
  G.writeWorkflowOff("x-ord-both");
  G.writeYield("x-ord-both");
  assert.deepStrictEqual(shouldYieldOrBypass("x-ord-both"), { exit: true, reason: "workflow-off" },
    "the workflow-off marker is checked before the yield gate");
  G.writeControl("x-ord-proceed", "session-close-gate.json", { gate_action: "proceed" });
  assert.deepStrictEqual(shouldYieldOrBypass("x-ord-proceed"), { exit: false, reason: null },
    "a non-yield gate_action is no exit");
  const hatch = G.exitHatchText();
  assert.ok(/workflow-off/.test(hatch) && /yield/.test(hatch), `EXIT_HATCH_TEXT must name both exits: ${hatch}`);
});
caseEnd();

caseBegin("lane-a-and-lane-b-name-the-same-exits", "hooks/stop-final-report-guard.js");
test("lane-a-and-lane-b-name-the-same-exits", () => {
  const sid = "x-text-lane-b";
  G.writeLaneBState(sid);
  const b = G.runGuard(sid, G.writeTranscript(TRANSCRIPTS, sid, "Wrapping up."), SB);
  assert.strictEqual(b.rc, 2, `fixture: lane B must block: ${b.out}`);
  const hatch = G.exitHatchText();
  for (const shape of Object.keys(SHAPES)) {
    const a = laneA(`x-text-${shape}`, shape, null);
    assert.ok(a.reason.includes(hatch), `lane A ${shape} reason lacks EXIT_HATCH_TEXT:\n${a.reason}`);
  }
  assert.ok(b.reason.includes(hatch), `lane B reason lacks EXIT_HATCH_TEXT:\n${b.reason}`);
  assert.ok(b.reason.includes("<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>"), "lane B keeps its own exit");
});
caseEnd();

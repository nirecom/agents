#!/usr/bin/env node
// tests/hooks/feature-2771-presented-stages-of-text.js
// Tests: hooks/lib/confirm-continuation.js
// Tags: TL1, hooks, confirm-plan, presentation-receipt, confirm-continuation, scope:issue-specific
// #2771 D3b: presentedStagesOfText judges a given last text over the given stages only, and
// presentedStages keeps its textOnlyAnchor gate in front of it. gateFor / linkFor are injected,
// so no gate probe and no git lookup runs.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2771u-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const X = require("./feature-2650-confirm-continuation/fixture");
const { A, T, BASH, show } = X;

let failed = 0;
function check(name, ok, detail) {
  if (ok) { process.stdout.write(`PASS: ${name}\n`); return; }
  failed += 1;
  process.stdout.write(`FAIL: ${name} — ${typeof detail === "string" ? detail : show(detail)}\n`);
}

const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
const linkFor = (p) => ({ path: p, url: X.BLOB + path.basename(p) });
const gateOn = () => "ON";
// call(fn, args) -> the result, or {threw} when the export is missing or throws (a FAIL, never a crash).
function call(fn, args) {
  if (CC.__missing) return { threw: "confirm-continuation.js does not load: " + CC.__missing };
  if (typeof CC[fn] !== "function") return { threw: `${fn} is not exported` };
  try { return CC[fn](args); } catch (e) { return { threw: e.message }; }
}
const stagesOf = (r) => (Array.isArray(r) ? r.map((x) => x && x.stage) : r);
const exactly = (r, want) => Array.isArray(r) && show(stagesOf(r)) === show(want);

// Intent and outline both unapproved, both plans on disk: either may be presented.
const sid = X.uuidSid(2771);
X.F.writePlan(sid, "intent");
X.F.writePlan(sid, "outline");
X.F.writeState(sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "pending" }, []);
const L = { intent: X.linesFor(sid, "intent"), outline: X.linesFor(sid, "outline") };
const BOTH = "Here are the plans.\n\n" + L.intent.urlLine + "\n" + L.outline.urlLine;
const OUTLINE_ONLY = "Here is the plan.\n\n" + L.outline.urlLine;
const ofText = (lastText, stages, over) => call("presentedStagesOfText", Object.assign({ sid, lastText, stages, gateFor: gateOn, linkFor }, over || {}));

caseBegin("presented-stages-control", "hooks/lib/confirm-continuation.js");
{
  const e = A("a-t", T(BOTH));
  const r = call("presentedStages", { sid, tail: { lastTextEntry: e, lastAssistantEntry: e, lastTextBlock: BOTH }, gateFor: gateOn, linkFor });
  check("presentedStages: a text-only anchor closing on both link lines -> intent and outline (fixture control)", exactly(r, ["intent", "outline"]), r);
}
caseEnd();

caseBegin("presented-stages-of-text-normal", "hooks/lib/confirm-continuation.js");
{
  const r = ofText(OUTLINE_ONLY, ["outline"]);
  check("presentedStagesOfText: text closing on the outline line, stages [outline] -> [outline]", exactly(r, ["outline"]), r);
  const p = Array.isArray(r) ? r[0] : null;
  check("presentedStagesOfText: the entry carries absPath, a url receiptLink and contentSha",
    p && path.resolve(p.absPath) === path.resolve(L.outline.plan) && p.receiptLink && p.receiptLink.kind === "url" && typeof p.contentSha === "string" && p.contentSha !== "", p);
  const both = ofText(BOTH, ["intent", "outline"]);
  check("presentedStagesOfText: text closing on both lines, stages [intent, outline] -> both", exactly(both, ["intent", "outline"]), both);
}
caseEnd();

caseBegin("presented-stages-of-text-stays-within-stages", "hooks/lib/confirm-continuation.js");
{
  const r1 = ofText(BOTH, ["outline"]);
  check("presentedStagesOfText: text closing on intent and outline, stages [outline] -> only outline", exactly(r1, ["outline"]), r1);
  const r2 = ofText(BOTH, ["intent"]);
  check("presentedStagesOfText: text closing on intent and outline, stages [intent] -> only intent", exactly(r2, ["intent"]), r2);
  const r3 = ofText(OUTLINE_ONLY, ["intent"]);
  check("presentedStagesOfText: stages [intent], text closing only on outline -> []", exactly(r3, []), r3);
}
caseEnd();

caseBegin("presented-stages-of-text-not-presented", "hooks/lib/confirm-continuation.js");
{
  const r1 = ofText(OUTLINE_ONLY + "\n\nDoes this look right?", ["outline"]);
  check("presentedStagesOfText: a sentence after the link line -> []", exactly(r1, []), r1);
  const r2 = ofText(OUTLINE_ONLY, ["outline"], { gateFor: () => "OFF" });
  check("presentedStagesOfText: the stage's gate is OFF -> []", exactly(r2, []), r2);
  const s = X.sessionAt("outline", { tag: 2772, approved: true });
  const r3 = call("presentedStagesOfText", { sid: s.sid, lastText: "Here.\n\n" + s.urlLine, stages: ["outline"], gateFor: gateOn, linkFor });
  check("presentedStagesOfText: an approved stage -> []", exactly(r3, []), r3);
}
caseEnd();

caseBegin("presented-stages-of-text-boundaries", "hooks/lib/confirm-continuation.js");
{
  for (const [label, v] of [["empty string", ""], ["null", null], ["undefined", undefined], ["a number", 42]]) {
    const r = ofText(v, ["outline"]);
    check(`presentedStagesOfText: lastText ${label} -> []`, exactly(r, []), r);
  }
  const r = ofText(OUTLINE_ONLY, []);
  check("presentedStagesOfText: stages [] -> []", exactly(r, []), r);
}
caseEnd();

caseBegin("presented-stages-keeps-text-only-anchor", "hooks/lib/confirm-continuation.js");
{
  const withTool = A("a-t", T(BOTH), BASH("ls", "b1"));
  const r1 = call("presentedStages", { sid, tail: { lastTextEntry: withTool, lastAssistantEntry: withTool, lastTextBlock: BOTH }, gateFor: gateOn, linkFor });
  check("presentedStages: the anchor entry holds a tool_use -> [] although its text closes on link lines", exactly(r1, []), r1);
  const text = A("a-t", T(BOTH));
  const later = A("a-b", BASH("ls", "b2"));
  const r2 = call("presentedStages", { sid, tail: { lastTextEntry: text, lastAssistantEntry: later, lastTextBlock: BOTH }, gateFor: gateOn, linkFor });
  check("presentedStages: lastTextEntry is not lastAssistantEntry -> []", exactly(r2, []), r2);
}
caseEnd();

process.stdout.write(`\n${failed === 0 ? "OK" : `${failed} failed`}\n`);
process.exitCode = failed === 0 ? 0 : 1;

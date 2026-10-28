#!/usr/bin/env node
// tests/hooks/feature-2771-presented-stages-of-text.js
// Tests: hooks/lib/confirm-continuation.js
// Tags: TL1, hooks, confirm-plan, presentation-receipt, confirm-continuation, scope:issue-specific
// #2771 D3b: presentedStagesOfText judges a given last text over the given stages only, and
// presentedStages keeps its textOnlyAnchor gate in front of it. gateFor / linkFor are injected,
// so no gate probe and no git lookup runs.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
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

// check(name, ok, detail) — one node:test test over a verdict computed now.
function check(name, ok, detail) {
  const why = typeof detail === "string" ? detail : show(detail);
  test(name, () => { if (!ok) assert.fail(why); });
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

// #2804 Step 4: presentAgainReason reads as one procedure — present via the plan-link line and close
// the turn, then the echo alone when Stop returns "[confirm-plan] continue:", else after the user's reply.
const CONTINUE_CORE = (S) => `[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the approval dialog follows.`;
// againOf(stage, cause) -> the reason from "[confirm-plan] present" on (a CONV_LANG prefix is cut off), or {threw}.
function againOf(stage, cause) {
  if (CC.__missing || typeof CC.presentAgainReason !== "function") return { threw: "presentAgainReason is not available" };
  try {
    const r = String(CC.presentAgainReason(stage, cause));
    const i = r.indexOf("[confirm-plan] present");
    return i < 0 ? { threw: "no [confirm-plan] present head: " + r } : r.slice(i);
  } catch (e) { return { threw: e.message }; }
}

caseBegin("present-again-one-procedure", "hooks/lib/confirm-continuation.js");
{
  for (const stage of ["intent", "outline", "detail"]) {
    for (const cause of ["no-receipt", "not-last", "unpublished"]) {
      const t = againOf(stage, cause);
      const ok = typeof t === "string";
      // The command reads `node "$AGENTS_MAIN_ROOT/bin/plan-link" --stage <stage>`: plan-link, then --stage.
      const iStage = ok ? t.indexOf(`--stage ${stage}`) : -1;
      const iLink = iStage >= 0 && t.slice(0, iStage).includes("plan-link") ? iStage : -1;
      const iCont = ok && iLink >= 0 ? t.indexOf("[confirm-plan] continue:", iLink) : -1;
      const iReply = ok && iCont >= 0 ? t.indexOf("reply", iCont) : -1;
      check(`presentAgainReason(${stage}, ${cause}): plan-link --stage, then the continue: echo, then the user's reply, in that order`,
        iLink >= 0 && iCont > iLink && iReply > iCont, { iLink, iCont, iReply, t });
      check(`presentAgainReason(${stage}, ${cause}): the old "echo only after the reply" ending is gone`,
        ok && !t.includes("echo the CONFIRM only after the user's reply"), t);
    }
  }
}
caseEnd();

// branchesOf(t) -> {cont, other}: the text from "[confirm-plan] continue:" up to the first ";", and after it.
function branchesOf(t) {
  const i = typeof t === "string" ? t.indexOf("[confirm-plan] continue:") : -1;
  if (i < 0) return null;
  const rest = t.slice(i);
  const j = rest.indexOf(";");
  return j < 0 ? null : { cont: rest.slice(0, j), other: rest.slice(j + 1) };
}
// The continue branch emits only the echo and waits for nothing; the other branch echoes after the reply.
const contBranchOk = (b) => !!b && /emit only the CONFIRM echo/.test(b.cont) && !/reply|wait/i.test(b.cont);
const otherBranchOk = (b) => !!b && /without that prompt/.test(b.other) && /echo the CONFIRM after the user's reply/.test(b.other);

caseBegin("present-again-branch-wording", "hooks/lib/confirm-continuation.js");
{
  for (const stage of ["intent", "outline", "detail"]) {
    for (const cause of ["no-receipt", "not-last", "unpublished"]) {
      const b = branchesOf(againOf(stage, cause));
      check(`presentAgainReason(${stage}, ${cause}): the continue: branch emits only the echo, with no wait for a reply`, contBranchOk(b), b);
      check(`presentAgainReason(${stage}, ${cause}): the other branch echoes after the user's reply`, otherBranchOk(b), b);
    }
  }
  // Mutation probe: a contradictory wording with the same keyword order must be rejected.
  const flipped = "[confirm-plan] present the outline plan again (no-receipt): x. Run plan-link --stage outline, " +
    "close the turn. When the turn end then returns \"[confirm-plan] continue:\", wait for the user's reply before you emit only the CONFIRM echo; " +
    "without that prompt, emit only the CONFIRM echo at once.";
  const fb = branchesOf(flipped);
  check("probe: a continue: branch that waits for the reply is rejected", fb !== null && !contBranchOk(fb), fb);
  check("probe: an other branch that echoes at once is rejected", fb !== null && !otherBranchOk(fb), fb);
  check("probe: a text without the continue: marker yields no branches", branchesOf("present again; echo after the reply") === null, "branches found");
}
caseEnd();

caseBegin("continue-reason-unchanged", "hooks/lib/confirm-continuation.js");
{
  for (const stage of ["intent", "outline", "detail"]) {
    let r;
    try { r = String(CC.continueReason(stage)); } catch (e) { r = "threw: " + e.message; }
    check(`continueReason(${stage}): still carries the exact continue core`, r.includes(CONTINUE_CORE(stage.toUpperCase())), r);
  }
}
caseEnd();

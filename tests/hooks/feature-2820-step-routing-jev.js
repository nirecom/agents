"use strict";
// Tests: hooks/workflow-state/complexity-routing.js, hooks/lib/jev/broker.js, hooks/lib/jev/decision-record.js
// Tags: TL2, hooks, complexity, routing, jev, broker, decision-record, rename, scope:issue-specific
// #2820: the complexity-routing family is named by workflow step, and the Jev step -> ticket stage
// map is jevTicketStageOfStep. The Jev ticket / decision record `stage` field keeps its values.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.resolve(__dirname, "..", "..");
const ADAPTER_JS = path.join(REPO, "bin", "workflow", "lib", "jev-complexity-adapter.js");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2820-srj-"));
const SAVED = { AGENTS_STATE_DIR: process.env.AGENTS_STATE_DIR, JEV: process.env.JEV };
// The broker logs and keeps its pending hand-offs under AGENTS_STATE_DIR; JEV gates it.
process.env.AGENTS_STATE_DIR = path.join(ROOT, "state");
process.env.JEV = "on";
after(() => {
  for (const [k, v] of Object.entries(SAVED)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

caseBegin("routing-family-named-by-step", "hooks/workflow-state/complexity-routing.js");
const CR = require(path.join(REPO, "hooks", "workflow-state", "complexity-routing.js"));
const RENAMED = ["ROUTING_STEPS", "STEP_ROUTING", "deriveStepLevel", "deriveStepLevels", "deriveLegacyStepLevels",
  "describeStepRouting", "renderStepRoutingMarkdown"];
const RETIRED = ["ROUTING_STAGES", "STAGE_ROUTING", "deriveStageLevel", "deriveStageLevels", "deriveLegacyStageLevels",
  "describeStageRouting", "renderStageRoutingMarkdown"];
test("the step-named routing exports are present", () => {
  for (const k of RENAMED) assert.ok(k in CR, `${k} is exported`);
});
test("the retired stage-named routing exports are absent", () => {
  for (const k of RETIRED) assert.ok(!(k in CR), `${k} must not be exported`);
});
test("describeStepRouting labels each routing step with `step: <step>`", () => {
  for (const step of CR.ROUTING_STEPS) {
    const d = CR.describeStepRouting(step);
    assert.ok(d.startsWith(`step: ${step}`), `${step}: ${d}`);
    assert.ok(!d.includes("stage: "), `${step}: no stage label in ${d}`);
  }
});
test("renderStepRoutingMarkdown heads its first column `| Step |`", () => {
  const header = CR.renderStepRoutingMarkdown().split("\n")[0];
  assert.ok(header.startsWith("| Step |"), header);
  assert.ok(!header.includes("| Stage |"), header);
});
caseEnd();

caseBegin("decision-record-ticket-stage-of-step", "hooks/lib/jev/decision-record.js");
const record = require(path.join(REPO, "hooks", "lib", "jev", "decision-record.js"));
const adapter = require(ADAPTER_JS);
test("observedPending re-derives the stage field with jevTicketStageOfStep from the validated step", () => {
  assert.strictEqual(typeof adapter.jevTicketStageOfStep, "function", "the adapter exports jevTicketStageOfStep");
  const seen = [];
  const map = (s) => { seen.push(s); return adapter.jevTicketStageOfStep(s); };
  const p = record.observedPending({ step: "write_code", stage: "forged" }, map);
  assert.deepStrictEqual(seen, ["write_code"]);
  assert.strictEqual(p.step, "write_code");
  assert.strictEqual(p.stage, "write_code", "the ticket stage value is unchanged");
});
test("buildRecord keeps the `stage` field carrying the ticket stage", () => {
  const rec = record.buildRecord({ point: "complexity-judge", sessionId: "sid-2820", toolUseId: "toolu_2820_dr",
    pending: null, step: "clarify_intent", stage: adapter.jevTicketStageOfStep("clarify_intent"),
    llm: { status: "ok", answer: "S2-architecture" }, mode: "shadow", adopted: "llm" });
  assert.strictEqual(rec.step, "clarify_intent");
  assert.strictEqual(rec.stage, "cos1");
});
caseEnd();

caseBegin("broker-ticket-stage-of-step", "hooks/lib/jev/broker.js");
const broker = require(path.join(REPO, "hooks", "lib", "jev", "broker.js"));
const pending = require(path.join(REPO, "hooks", "lib", "jev", "pending.js"));
const { registryEntry, recordingOwner } = require(path.join(REPO, "hooks", "lib", "jev", "registry.js"));
const SID = "sid-2820";
// spyStageMap(): routes the broker's adapter.jevTicketStageOfStep through a call recorder.
function spyStageMap() {
  const real = adapter.jevTicketStageOfStep;
  assert.strictEqual(typeof real, "function", "the adapter exports jevTicketStageOfStep");
  const calls = [];
  adapter.jevTicketStageOfStep = (s) => { calls.push(s); return real(s); };
  return { calls, done: () => { adapter.jevTicketStageOfStep = real; } };
}
// hand(tid, step): the pre hook's hand-off for a complexity-judge dispatch at step.
function hand(tid, step) {
  const e = registryEntry("complexity-judge");
  return { point: "complexity-judge", mode: e.mode, recording_owner: recordingOwner(e), session_id: SID,
    tool_use_id: tid, step, stage: "forged", input: { bytes: 0, sha256: null, truncated: false, sources: [] },
    jev: broker.jevResult("not-run"), executor_model: "sonnet", llm_dispatch_ts: Date.now() };
}
const record2820 = (step, tid) => broker.recordShadow({ point: "complexity-judge", sessionId: SID, toolUseId: tid,
  llmText: "SIGNALS: S2-architecture", toolInput: { subagent_type: "complexity-judge" }, step });
test("recordShadow without a hand-off: the record's stage is jevTicketStageOfStep(step)", () => {
  const spy = spyStageMap();
  try {
    const ci = record2820("clarify_intent", "toolu_2820_ci");
    const rs = record2820("research", "toolu_2820_rs");
    assert.deepStrictEqual([ci.step, ci.stage], ["clarify_intent", "cos1"]);
    assert.deepStrictEqual([rs.step, rs.stage], ["research", "unknown"]);
    assert.ok(spy.calls.includes("clarify_intent") && spy.calls.includes("research"), `calls: ${spy.calls}`);
  } finally { spy.done(); }
});
test("recordShadow paired with a hand-off: the forged stage is re-derived through jevTicketStageOfStep", () => {
  pending.writePending(SID, "toolu_2820_wt", hand("toolu_2820_wt", "write_tests"));
  const spy = spyStageMap();
  try {
    const r = record2820("write_tests", "toolu_2820_wt");
    assert.deepStrictEqual([r.step, r.stage], ["write_tests", "write_tests"]);
    assert.ok(spy.calls.includes("write_tests"), `calls: ${spy.calls}`);
  } finally { spy.done(); }
});
test("an orphan sweep records the ticket stage re-derived through jevTicketStageOfStep", () => {
  pending.writePending(SID, "toolu_2820_or", hand("toolu_2820_or", "write_code"));
  const old = new Date(Date.now() - 3600000);
  const dir = path.join(process.env.AGENTS_STATE_DIR, "jev", SID, "pending");
  for (const n of fs.readdirSync(dir)) fs.utimesSync(path.join(dir, n), old, old);
  const spy = spyStageMap();
  try {
    assert.strictEqual(broker.sweepSession(SID, { pendingTtlMs: 60000 }), 1);
    assert.ok(spy.calls.includes("write_code"), `calls: ${spy.calls}`);
  } finally { spy.done(); }
  const recs = fs.readFileSync(record.decisionLogPath(), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const r = recs.find((x) => x.tool_use_id === "toolu_2820_or");
  assert.ok(r, "the orphan was logged");
  assert.deepStrictEqual([r.step, r.stage, r.llm.status], ["write_code", "write_code", "missing"]);
});
caseEnd();

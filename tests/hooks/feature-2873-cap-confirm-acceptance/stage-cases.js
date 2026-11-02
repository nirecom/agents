"use strict";
// #2873 T3/T4 cases: recordStageCapAcceptance accepts the plan stage's own last run (lastStageRun),
// not the session's last terminal run, so a later TR4 / TR5 run cannot hide the stage's capped
// WARN / CONTINUE from the CONFIRM Allow. Every refusal writes nothing. Seeded supervisor state, in
// process. Called from ../feature-2873-cap-confirm-acceptance.js, which owns the case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const writer = mod("hooks/lib/supervisor-state-writer");
const schema = mod("hooks/lib/supervisor-state-schema.js");
const PCA = mod("hooks/lib/pre-confirm-audit.js");
const SBO = mod("hooks/lib/supervisor-block-override.js");
const show = (v) => JSON.stringify(v);
const REASON = "CONFIRM_OUTLINE Allow at the audit run cap: reviewed with the user";
const REPORTER = "workflow-mark:confirm-cap-acceptance";
const ctx = () => ({ cwd: path.dirname(process.env.WORKFLOW_STATE_DIR) });
const STAGES = [
  { step: "clarify_intent", tr: "TR1", actor: "CONFIRM_INTENT" },
  { step: "outline", tr: "TR2", actor: "CONFIRM_OUTLINE" },
  { step: "detail", tr: "TR3", actor: "CONFIRM_DETAIL" },
];

let n = 0;
const nextSid = (tag) => `f2873-${tag}-${++n}`;
function run(id, tr, verdict, outcome) {
  const trs = Array.isArray(tr) ? tr : [tr];
  return { id, outcome: outcome || "terminal", cause: `pre-confirm:${trs[0]}`, tr_ids: trs, verdict,
    freshness_key: "fk", trigger_input_keys: Object.fromEntries(trs.map((t) => [t, `k-${t}`])) };
}
// seed(sid, runs, counts) -> writes supervisor state whose last terminal run is the last terminal entry.
function seed(sid, runs, counts) {
  const st = schema.createEmptyState(sid);
  const terminal = runs.filter((r) => r.outcome === "terminal");
  const last = terminal[terminal.length - 1] || {};
  Object.assign(st.audit, { ledger: runs, last_terminal_run_id: last.id || null, audit_verdict_summary: last.verdict || null,
    audit_run_counts: counts });
  const p = writer.getStatePath(sid, { forWrite: true });
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(st));
  return sid;
}
const overrides = (sid) => (((writer.readState(sid) || {}).audit || {}).block_overrides) || [];
function stageAccept(sid, step, runId, extra) {
  assert.strictEqual(typeof SBO.recordStageCapAcceptance, "function", "recordStageCapAcceptance is exported");
  return SBO.recordStageCapAcceptance(sid, Object.assign({ step, runId, reason: REASON, actor: "CONFIRM_OUTLINE", reporter: REPORTER }, extra || {}));
}
// The stage's capped run, then a later TR4 terminal run: the session's last terminal run is not the stage's.
const hidden = (sid, tr, verdict) => seed(sid, [run("run-0001", tr, verdict || "WARN"), run("run-0002", "TR4", "CONTINUE")], { [tr]: 3 });

function lastStageRunExported() {
  assert.strictEqual(typeof PCA.lastStageRun, "function", "lastStageRun is exported");
  const audit = { ledger: [run("run-0001", "TR2", "WARN"), run("run-0002", "TR4", "CONTINUE")] };
  assert.strictEqual((PCA.lastStageRun(audit, "TR2") || {}).id, "run-0001");
  assert.strictEqual(PCA.lastStageRun(audit, "TR3"), null);
}

function recordsHiddenStageRun() {
  const sid = hidden(nextSid("hidden"), "TR2");
  const r = stageAccept(sid, "outline", "run-0001");
  assert.ok(r && r.ok, `refused: ${show(r)}`);
  const recs = overrides(sid);
  assert.strictEqual(recs.length, 1, show(recs));
  assert.strictEqual(recs[0].run_id, "run-0001");
  assert.strictEqual(recs[0].verdict, "WARN");
  assert.strictEqual(recs[0].actor, "CONFIRM_OUTLINE");
  assert.strictEqual(recs[0].trigger_key, "k-TR2", show(recs[0]));
}

function acceptanceReleasesStage() {
  for (const s of STAGES) {
    for (const verdict of ["WARN", "CONTINUE"]) {
      const sid = hidden(nextSid(`rel-${s.tr}`), s.tr, verdict);
      const r = stageAccept(sid, s.step, "run-0001", { actor: s.actor });
      const tag = `[${s.step} ${verdict}]`;
      assert.ok(r && r.ok, `${tag} refused: ${show(r)}`);
      assert.strictEqual(overrides(sid)[0].verdict, verdict, `${tag} ${show(overrides(sid))}`);
      assert.strictEqual(overrides(sid)[0].actor, s.actor, tag);
      const acc = PCA.acceptedOnError(sid, s.step);
      assert.ok(acc.accepted === true && acc.runId === "run-0001", `${tag} acceptedOnError ${show(acc)}`);
      assert.strictEqual(PCA.judgeStage(sid, s.step, ctx()).state, "accepted", `${tag} judgeStage`);
    }
  }
}

function reviewedRefusalGuidesToConfirm() {
  const sid = hidden(nextSid("guide"), "TR2");
  const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: "run-0001", reason: REASON, actor: "tester" });
  assert.strictEqual(r.code, "not-last-terminal-run", show(r));
  assert.ok(r.message.includes("CONFIRM") && /\bON\b/.test(r.message) && r.message.includes("next-step --gate"), `guidance: ${r.message}`);
  assert.deepStrictEqual(overrides(sid), []);
  const tr5 = hidden(nextSid("guide5"), "TR5");
  const r5 = SBO.recordReviewedVerdictAcceptance(tr5, { runId: "run-0001", reason: REASON, actor: "tester" });
  assert.strictEqual(r5.code, "not-last-terminal-run", show(r5));
  assert.ok(!r5.message.includes("CONFIRM"), `a TR5 run gets no CONFIRM guidance: ${r5.message}`);
}

// Each refusal fixture breaks exactly one condition, so the code does not depend on check order.
const REFUSALS = [
  { code: "not-capped", sid: () => seed(nextSid("nc"), [run("run-0001", "TR2", "WARN")], { TR2: 2 }) },
  { code: "not-last-stage-run", sid: () => seed(nextSid("nl"), [run("run-0001", "TR2", "WARN"), run("run-0002", "TR2", "WARN")], { TR2: 3 }) },
  { code: "run-not-terminal", sid: () => seed(nextSid("nt"), [run("run-0000", "TR4", "CONTINUE"), run("run-0001", "TR2", "WARN", "discarded-stale")], { TR2: 3 }) },
  { code: "verdict-not-acceptable", sid: () => hidden(nextSid("bl"), "TR2", "BLOCK"), msg: "VERDICT_ACCEPTED" },
  { code: "reason-too-short", sid: () => hidden(nextSid("rs"), "TR2"), extra: { reason: "too short reason" } },
  { code: "not-a-plan-stage", sid: () => hidden(nextSid("np"), "TR2"), step: "write_code" },
  { code: "invalid-session", sid: () => "bad sid!" },
  { code: "no-state", sid: () => nextSid("none") },
];

function refusalsWriteNothing() {
  for (const c of REFUSALS) {
    const sid = c.sid();
    const r = stageAccept(sid, c.step || "outline", "run-0001", c.extra);
    assert.strictEqual(r && r.ok, false, `${c.code}: must refuse; got ${show(r)}`);
    assert.strictEqual(r.code, c.code, `${c.code}: ${show(r)}`);
    if (c.msg) assert.ok(String(r.message).includes(c.msg), `${c.code}: message ${r.message}`);
    if (c.code !== "invalid-session") assert.deepStrictEqual(overrides(sid), [], `${c.code}: nothing written`);
  }
}

// A run covering a plan stage and TR5 keeps the TR5 verdict set (WARN / BLOCK): its CONTINUE is
// not accepted, while the same run with WARN is. Only an all-TR1-3 run takes the stage set.
function mixedTrRunKeepsTr5Set() {
  const cont = seed(nextSid("mix-c"), [run("run-0061", ["TR2", "TR5"], "CONTINUE")], { TR2: 1 });
  const rc = SBO.recordReviewedVerdictAcceptance(cont, { runId: "run-0061", reason: REASON, actor: "tester" });
  assert.strictEqual(rc.code, "verdict-not-acceptable", `[TR2,TR5] CONTINUE: ${show(rc)}`);
  assert.deepStrictEqual(overrides(cont), [], "[TR2,TR5] CONTINUE: nothing written");
  const warn = seed(nextSid("mix-w"), [run("run-0062", ["TR2", "TR5"], "WARN")], { TR2: 1 });
  const rw = SBO.recordReviewedVerdictAcceptance(warn, { runId: "run-0062", reason: REASON, actor: "tester" });
  assert.ok(rw.ok, `[TR2,TR5] WARN: ${show(rw)}`);
  const stage = seed(nextSid("mix-s"), [run("run-0063", ["TR2", "TR3"], "CONTINUE")], { TR2: 1, TR3: 1 });
  const rs = SBO.recordReviewedVerdictAcceptance(stage, { runId: "run-0063", reason: REASON, actor: "tester" });
  assert.ok(rs.ok, `[TR2,TR3] CONTINUE takes the stage set: ${show(rs)}`);
}

module.exports = {
  lastStageRunExported, recordsHiddenStageRun, acceptanceReleasesStage, reviewedRefusalGuidesToConfirm,
  refusalsWriteNothing, mixedTrRunKeepsTr5Set,
};

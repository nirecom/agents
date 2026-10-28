"use strict";
// Tests: hooks/workflow-gate/supervisor-check.js, hooks/workflow-gate.js
// Tags: TL2, hooks, supervisor, pre-merge, freshness-backstop, null-freshness, acceptance, newer-audit-unsettled, scope:issue-specific
// #2597 / #2521 / #2534 — the pre-merge backstop honours a reviewed verdict acceptance on the null
// path (T-PM1..T-PM3), denies a fresh non-null verdict while a newer run is unsettled (T-PM4..T-PM6),
// does not self-block right after USER_VERIFIED approves (T-PM7), and refuses an acceptance with
// no comparand at all (#2534).
// TL3 gap (what this test does NOT catch):
// - a real claude -p session firing the PreToolUse hook; the gate-wiring case spawns workflow-gate.js directly
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const X = require("./feature-2698-supervisor/fixture");
const S = require("./feature-2698-supervisor/audit-scene");
const U = require("./feature-2698-supervisor/uv-scene");

const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = X.tmpRoot("pm");
after(() => { restore(); X.rmRoot(ROOT); });

const { writePlans, fresh, run, seedRuns, record, tr5At, preMerge, accept, overridesOf } = U;
const { scene, gitRepo } = U.make(ROOT);
const PASS = "PASS";

// nullScene(tag, verdicts) -> an outline-less session (artifact-side null key) whose last TR5 runs carry verdicts.
function nullScene(tag, verdicts = ["WARN", "WARN"]) {
  const s = scene(tag);
  const repo = gitRepo();
  writePlans(s, ["intent", "detail"]);
  const f = fresh(s, repo);
  assert.ok(f.freshness_key === null && typeof f.input_version === "string", `artifact-side null key: ${JSON.stringify(f)}`);
  seedRuns(s, verdicts.map((v, i) => run(`run-000${4 + i}`, v, f)));
  return { s, repo, f };
}
// nonNullScene(tag) -> all three plans present, so the freshness key is computable.
function nonNullScene(tag) {
  const s = scene(tag);
  const repo = gitRepo();
  writePlans(s, ["intent", "outline", "detail"]);
  const f = fresh(s, repo);
  assert.ok(typeof f.freshness_key === "string", `non-null key: ${JSON.stringify(f)}`);
  return { s, repo, f };
}

caseBegin("pm-null-key-acceptance", "hooks/workflow-gate/supervisor-check.js");
test("T-PM1: null key, WARN runs, no acceptance -> deny", () => {
  const { s, repo } = nullScene("pm1");
  assert.notStrictEqual(preMerge(s, repo), PASS);
});
test("T-PM2/T-PM3: an acceptance recorded through the handler passes; a moved artifact denies again", () => {
  const { s, repo } = nullScene("pm2");
  const msg = accept(s, "run-0005");
  assert.deepStrictEqual(overridesOf(s).map((o) => [o.run_id, o.verdict]), [["run-0005", "WARN"]], `recorded (${msg})`);
  assert.strictEqual(preMerge(s, repo), PASS, "T-PM2: the accepted WARN passes the backstop");
  writePlans(s, ["detail"], "v2");
  assert.notStrictEqual(preMerge(s, repo), PASS, "T-PM3: the acceptance lapses once detail.md moves");
});
test("T-PM2 control: an acceptance pinned to another run never releases the last TR5 run", () => {
  const { s, repo, f } = nullScene("pm2c");
  X.seedSup(s.dir, s.sid, { audit: Object.assign(S.auditOf(s), { block_overrides: [record("run-0004", "WARN", f)] }) });
  assert.notStrictEqual(preMerge(s, repo), PASS);
});
test("T-PM2 control: an acceptance whose verdict differs from the run's never releases it", () => {
  const { s, repo, f } = nullScene("pm2v");
  X.seedSup(s.dir, s.sid, { audit: Object.assign(S.auditOf(s), { block_overrides: [record("run-0005", "BLOCK", f)] }) });
  assert.notStrictEqual(preMerge(s, repo), PASS);
});
test("T-PM2 control: a legacy record (no verdict, artifact_keys, trigger_key) never releases a null key", () => {
  const { s, repo } = nullScene("pm2l", ["WARN", "BLOCK"]);
  X.seedSup(s.dir, s.sid, { audit: Object.assign(S.auditOf(s), { block_overrides: [{ run_id: "run-0005",
    freshness_key: "legacy-fk", reason: U.REASON, actor: "t", recorded_at: U.now() }] }) });
  assert.notStrictEqual(preMerge(s, repo), PASS);
});
caseEnd();

caseBegin("pm-zero-comparands-acceptance-refused", "hooks/workflow-gate/supervisor-check.js");
test("#2534: code side null and every plan artifact absent -> an acceptance never passes the backstop", () => {
  const s = scene("pm0");
  const f = fresh(s, s.dir);
  assert.ok(f.input_version === null && Object.values(f.artifact_keys).every((v) => v === null), JSON.stringify(f));
  seedRuns(s, [run("run-0005", "WARN", f)], { block_overrides: [record("run-0005", "WARN", f)] });
  assert.notStrictEqual(preMerge(s, s.dir), PASS);
});
caseEnd();

caseBegin("pm-non-null-unsettled-run-denies", "hooks/workflow-gate/supervisor-check.js");
test("T-PM4: fk matches, but a newer run is pending / in_progress / frozen -> deny naming that run", () => {
  for (const phase of ["pending", "in_progress", "frozen"]) {
    const { s, repo, f } = nonNullScene(`pm4${phase.replace("_", "")}`);
    U.unsettledSlot(s, [run("run-0011", "CONTINUE", f)], phase);
    const r = preMerge(s, repo);
    assert.notStrictEqual(r, PASS, `${phase}: denied`);
    assert.ok(r.includes("run-0012"), `${phase}: the reason names the unsettled run-0012 (${r})`);
  }
});
test("T-PM5: the same state with the slot done -> pass (regression)", () => {
  const { s, repo, f } = nonNullScene("pm5");
  seedRuns(s, [run("run-0011", "CONTINUE", f)]);
  assert.strictEqual(preMerge(s, repo), PASS);
});
test("T-PM6: a valid BLOCK acceptance does not outrank a newer unsettled run -> deny", () => {
  const { s, repo, f } = nonNullScene("pm6");
  U.unsettledSlot(s, [run("run-0011", "BLOCK", f)], "pending", { block_overrides: [record("run-0011", "BLOCK", f)] });
  const r = preMerge(s, repo);
  assert.notStrictEqual(r, PASS);
  assert.ok(r.includes("run-0012"), `the reason names the unsettled run-0012 (${r})`);
});
test("T-PM6 control: the same BLOCK acceptance with the slot done -> pass", () => {
  const { s, repo, f } = nonNullScene("pm6c");
  seedRuns(s, [run("run-0011", "BLOCK", f)], { block_overrides: [record("run-0011", "BLOCK", f)] });
  assert.strictEqual(preMerge(s, repo), PASS);
});
caseEnd();

// T-PM1..T-PM3 through the real PreToolUse entry with a merge command: the merge routing reaches
// the backstop and the backstop honours the recorded acceptance.
caseBegin("pm-real-gate-null-key-warn-acceptance", "hooks/workflow-gate.js");
test("real gate: a null-key WARN merge is denied before acceptance, approved after it, denied once a comparand moves", () => {
  const { s, repo } = nullScene("pmg");
  const r0 = U.realGate(s, U.MERGE_CMD, repo);
  assert.strictEqual(r0.decision, "block", `before acceptance: the merge is denied (${r0.reason})`);
  const msg = accept(s, "run-0005");
  assert.deepStrictEqual(overridesOf(s).map((o) => [o.run_id, o.verdict]), [["run-0005", "WARN"]], `recorded (${msg})`);
  const r1 = U.realGate(s, U.MERGE_CMD, repo);
  assert.strictEqual(r1.decision, "approve", `after the acceptance: the merge passes (${r1.reason})`);
  writePlans(s, ["detail"], "v2");
  const r2 = U.realGate(s, U.MERGE_CMD, repo);
  assert.strictEqual(r2.decision, "block", `after detail.md moves: denied again (${r2.reason})`);
  writePlans(s, ["detail"], "v1");
  assert.strictEqual(U.realGate(s, U.MERGE_CMD, repo).decision, "approve", "premise: detail.md restored passes again");
  fs.writeFileSync(path.join(repo, "seed.txt"), "seed changed after the audit\n");
  const r3 = U.realGate(s, U.MERGE_CMD, repo);
  assert.strictEqual(r3.decision, "block", `after the code diff moves: denied again (${r3.reason})`);
});
caseEnd();

caseBegin("pm-no-self-block-after-user-verified", "hooks/workflow-gate/supervisor-check.js");
test("T-PM7: USER_VERIFIED approves a settled fresh run, and the pre-merge check on that state passes", () => {
  const { s, repo, f } = nonNullScene("pm7");
  seedRuns(s, [run("run-0011", "CONTINUE", f)]);
  assert.strictEqual(tr5At(s, repo), "APPROVE", "USER_VERIFIED approves");
  const phase = S.auditOf(s).audit_phase;
  assert.ok(!["pending", "in_progress", "frozen"].includes(phase), `approval leaves no unsettled slot (phase ${phase})`);
  assert.strictEqual(preMerge(s, repo), PASS, "the backstop does not self-block");
});
caseEnd();

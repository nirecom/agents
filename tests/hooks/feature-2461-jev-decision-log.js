#!/usr/bin/env node
// tests/hooks/feature-2461-jev-decision-log.js
// Tests: hooks/lib/jev/decision-record.js, hooks/lib/jev/broker.js, hooks/lib/jev/two-stage/merge.js, hooks/lib/jev/two-stage/replay.js, hooks/lib/temporary-migrations/jev-decision-log-rename.js
// Tags: TL2, hooks, jev, decision-log, judged-in, executor, migration, mock-server, scope:issue-specific, pwsh-not-required
// #2461 Step 1: every record path (recordShadow, orphanRecord, ticketRecord for complexity and
// skip, absentRecord, the two-stage orphan, settleRecord, both conversation points) carries
// the eight Scope-3 fields; llm.executor and judged_in follow the Step 1 table, old hands
// (no judged_in) included; jev-decisions.log* moves once to jev-decisions.jsonl*.
// TL3 gap: a real Claude Code session writing through the shadow hooks and jev-judge on a host
// that still holds an old log. Mitigation: the real jev-judge CLI and broker run here.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2461-jev/fixture");
const J = require("./feature-2677-jev/jj-fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2461dl-"));
const mock = F.startMock(path.join(ROOT, "mock"));
after(() => {
  mock.stop();
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const DR = F.lib("hooks/lib/jev/decision-record.js");
const BROKER = F.lib("hooks/lib/jev/broker.js");
const PENDING = F.lib("hooks/lib/jev/pending.js");
const CONV = F.lib("hooks/lib/jev/conversation-point.js");
const SCOPE3 = ["point", "judged_in", "step", "session_id", "final", "threshold", "adopted", "fallback_reason"];
const JUDGE = { kind: "cli", name: "jev-judge" };

// scope3(rec) -> the Scope-3 fields the record lacks ([] when complete).
function scope3(rec) {
  const miss = SCOPE3.filter((k) => !rec || !Object.prototype.hasOwnProperty.call(rec, k));
  if (!rec || !rec.jev || !Object.prototype.hasOwnProperty.call(rec.jev, "probabilities")) miss.push("jev.probabilities");
  return miss;
}
// child(sc, code, args, extra) -> the JSON the child printed last (asserts exit 0).
function child(sc, code, args = [], extra) {
  const r = F.nodeEval(sc, mock, code, args, extra);
  assert.strictEqual(r.status, 0, `child exit 0 (stderr: ${r.stderr.slice(0, 600)})`);
  return r.json;
}
const handPath = (fx, tid) => path.join(fx.dir, "state", "jev", J.SID, "pending", `${tid}.json`);
// dropJudgedIn(fx, tid) — turn a fresh ticket hand into a pre-#2461 one (no judged_in).
function dropJudgedIn(fx, tid) {
  const h = JSON.parse(fs.readFileSync(handPath(fx, tid), "utf8"));
  delete h.judged_in;
  fs.writeFileSync(handPath(fx, tid), JSON.stringify(h));
}
// cxNeed(name) -> {fx, ticket}: a complexity query that delegates S3 (held at p=0.5).
function cxNeed(name) {
  const fx = J.newFx(ROOT, name);
  mock.probs(0.01, { "S3-security": 0.5 });
  const q = J.cxQuery(fx, mock, "complexity");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise: the query delegates (stdout: ${q.stdout})`);
  return { fx, ticket: q.kv("TICKET") };
}
const logOf = (fx) => (fs.existsSync(fx.log) ? fs.readFileSync(fx.log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);

caseBegin("build-record-executor-and-judged-in", "hooks/lib/jev/decision-record.js");
test("LOG_NAME is jev-decisions.jsonl and EXECUTOR is gone", () => {
  const sc = F.scene(ROOT, "names");
  const o = child(sc, `const d = require(${JSON.stringify(DR)});
console.log(JSON.stringify({ name: d.LOG_NAME, exec: d.EXECUTOR === undefined ? "<undefined>" : d.EXECUTOR }));`);
  assert.deepStrictEqual(o, { name: "jev-decisions.jsonl", exec: "<undefined>" });
});
test("buildRecord: executor from entry.backup_subagent (string, null, registry); judged_in from judgedIn else null", () => {
  const sc = F.scene(ROOT, "build");
  const o = child(sc, `const d = require(${JSON.stringify(DR)});
const base = { point: "complexity-judge", sessionId: process.argv[2], toolUseId: "toolu_b1", pending: null, step: "detail", stage: "detail",
  llm: { status: "ok", answer: "S1-multi-file" }, mode: "shadow", adopted: "llm" };
const th = { true: 0.7, false: null };
const r = (x) => d.buildRecord(Object.assign({}, base, x));
const a = r({ entry: { backup_subagent: "plan-skip-judge", confidence_threshold_by_answer: th }, judgedIn: { kind: "cli", name: "x" } });
const b = r({ entry: { backup_subagent: null, confidence_threshold_by_answer: th } });
const c = r({});
console.log(JSON.stringify({ a: [a.llm.executor, a.judged_in], b: [b.llm.executor, b.judged_in], c: [c.llm.executor, c.judged_in] }));`, [F.newSid()]);
  assert.deepStrictEqual(o.a, ["plan-skip-judge", { kind: "cli", name: "x" }]);
  assert.deepStrictEqual(o.b, [null, null]);
  assert.deepStrictEqual(o.c, ["complexity-judge", null], "no entry: the registry's backup_subagent");
});
caseEnd();

caseBegin("shadow-paths-judged-in", "hooks/lib/jev/broker.js");
test("queryShadow writes judged_in jev-shadow-pre into the hand; recordShadow records jev-shadow-post", () => {
  const sc = F.scene(ROOT, "shadow");
  const sid = F.newSid();
  mock.probs(0.02, { "S1-multi-file": 0.97 });
  const o = child(sc, `(async () => {
const b = require(${JSON.stringify(BROKER)});
const hand = await b.queryShadow({ point: "complexity-judge", sessionId: process.argv[2], toolUseId: "toolu_s1", toolInput: { prompt: "judge" }, step: "detail", cwd: process.cwd() });
const rec = b.recordShadow({ point: "complexity-judge", sessionId: process.argv[2], toolUseId: "toolu_s1", llmText: "SIGNALS: S1-multi-file", toolInput: {}, step: "detail" });
console.log(JSON.stringify({ hand: hand && hand.judged_in, rec }));
})();`, [sid]);
  assert.deepStrictEqual(o.hand, { kind: "hook", name: "jev-shadow-pre" });
  const recs = F.records(sc);
  assert.strictEqual(recs.length, 1, "one record in jev-decisions.jsonl");
  assert.deepStrictEqual(scope3(recs[0]), []);
  assert.deepStrictEqual(recs[0].judged_in, { kind: "hook", name: "jev-shadow-post" });
  assert.strictEqual(recs[0].llm.executor, "complexity-judge");
});
test("orphanRecord: the hand's judged_in; an old hand gets jev-shadow-pre", () => {
  const sc = F.scene(ROOT, "orphan");
  const sid = F.newSid();
  child(sc, `const p = require(${JSON.stringify(PENDING)});
const base = { point: "complexity-judge", mode: "shadow", recording_owner: "hook", session_id: process.argv[2], step: "detail",
  jev: { status: "ok", answer: "S2-architecture", probabilities: { s2_architecture: 0.97 } } };
p.writePending(process.argv[2], "toolu_new", Object.assign({ tool_use_id: "toolu_new", judged_in: { kind: "hook", name: "from-hand" } }, base));
p.writePending(process.argv[2], "toolu_old", Object.assign({ tool_use_id: "toolu_old" }, base));
console.log("{}");`, [sid]);
  F.sleepMs(50);
  child(sc, `require(${JSON.stringify(BROKER)}).sweepSession(process.argv[2], { pendingTtlMs: 1 }); console.log("{}");`, [sid]);
  const recs = F.records(sc);
  const by = (t) => recs.find((x) => x.tool_use_id === t);
  assert.ok(by("toolu_new") && by("toolu_old"), `both orphans recorded (got ${JSON.stringify(recs.map((x) => x.tool_use_id))})`);
  assert.deepStrictEqual(by("toolu_new").judged_in, { kind: "hook", name: "from-hand" });
  assert.deepStrictEqual(by("toolu_old").judged_in, { kind: "hook", name: "jev-shadow-pre" });
  for (const t of ["toolu_new", "toolu_old"]) {
    assert.deepStrictEqual(scope3(by(t)), [], t);
    assert.strictEqual(by(t).llm.executor, "complexity-judge", t);
  }
});
caseEnd();

caseBegin("two-stage-paths-judged-in", "hooks/lib/jev/two-stage/merge.js");
test("complexity ticket finalized: decision {cli, jev-judge}, executor complexity-judge; no settle record on SETTLE=ok", () => {
  const fx = J.newFx(ROOT, "cx-final");
  mock.probs(0.01, { "S2-architecture": 0.99 });
  const q = J.cxQuery(fx, mock, "complexity");
  assert.strictEqual(q.kv("RESULT"), "final", `premise (stdout: ${q.stdout})`);
  assert.strictEqual(J.finalize(fx, mock, q.kv("TICKET")).status, 0);
  const rec = J.decision(fx, q.kv("TICKET"));
  assert.ok(rec, "a decision record");
  assert.deepStrictEqual(scope3(rec), []);
  assert.deepStrictEqual(rec.judged_in, JUDGE);
  assert.strictEqual(rec.llm.executor, "complexity-judge");
  // A settle that went through (SETTLE=ok, not stale) leaves only the decision record.
  const settle = J.records(fx, q.kv("TICKET")).find((x) => x.record_type === "settle");
  assert.strictEqual(settle, undefined, "no settle record");
});
test("skip ticket finalized: decision {cli, jev-judge}, executor plan-skip-judge", () => {
  const fx = J.newFx(ROOT, "sk-final", { outline: true, stateJson: J.STATE_AT_DETAIL });
  mock.probs(0.5);
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.status, 0, `premise (stderr: ${q.stderr})`);
  assert.strictEqual(J.finalize(fx, mock, q.kv("TICKET")).status, 0);
  const rec = J.decision(fx, q.kv("TICKET"));
  assert.ok(rec, "a decision record");
  assert.deepStrictEqual(scope3(rec), []);
  assert.deepStrictEqual(rec.judged_in, JUDGE);
  assert.strictEqual(rec.llm.executor, "plan-skip-judge");
});
test("old ticket hand (no judged_in) finalized: decision still {cli, jev-judge}, no settle record", () => {
  const { fx, ticket } = cxNeed("cx-old");
  dropJudgedIn(fx, ticket);
  assert.strictEqual(J.finalize(fx, mock, ticket).status, 0);
  const rec = J.decision(fx, ticket);
  assert.ok(rec, "a decision record");
  assert.deepStrictEqual(rec.judged_in, JUDGE);
  assert.strictEqual(rec.llm.executor, "complexity-judge");
  const settle = J.records(fx, ticket).find((x) => x.record_type === "settle");
  assert.strictEqual(settle, undefined, "no settle record");
});
for (const old of [false, true]) {
  test(`two-stage orphan (absentRecord, ${old ? "old" : "new"} hand): finalize-absent, {cli, jev-judge}, executor complexity-judge`, () => {
    const { fx, ticket } = cxNeed(old ? "orph-old" : "orph-new");
    if (old) dropJudgedIn(fx, ticket);
    F.sleepMs(50);
    const s = J.probe(fx, mock, ["sweep", J.SID, "1"]);
    assert.strictEqual(s.status, 0, `sweep exit 0 (stderr: ${s.stderr})`);
    const rec = J.decision(fx, ticket);
    assert.ok(rec, `a decision record (log: ${JSON.stringify(logOf(fx)).slice(0, 300)})`);
    assert.strictEqual(rec.fallback_reason, "finalize-absent");
    assert.deepStrictEqual(scope3(rec), []);
    assert.deepStrictEqual(rec.judged_in, JUDGE);
    assert.strictEqual(rec.llm.executor, "complexity-judge");
  });
}
caseEnd();

caseBegin("conversation-records", "hooks/lib/jev/conversation-point.js");
for (const [point, direction, extra] of [
  ["continuation", "continue-on-stop", {}],
  ["askuser-answer", undefined, { questions: [{ question: "Pick one?", header: "Pick", multiSelect: false, options: [{ label: "A", description: "a" }, { label: "B", description: "b" }] }] }],
]) {
  test(`${point}: Scope-3 fields, judged_in from the caller, executor null`, () => {
    const sc = F.scene(ROOT, `conv-${point}`);
    const sid = F.newSid();
    const tp = F.writeTranscript(sc, "t", [F.U("go on"), F.A(F.T("I will now edit the next file."))]);
    mock.conv(0.02);
    child(sc, `(async () => {
const c = require(${JSON.stringify(CONV)});
await c.judgeConversation({ point: process.argv[2], direction: process.argv[3] || undefined, sessionId: process.argv[4], transcriptPath: process.argv[5],
  judgedIn: { kind: "hook", name: "caller-x" }, extra: JSON.parse(process.argv[6]),
  overrides: require(${JSON.stringify(F.lib("hooks/lib/jev/test-overrides.js"))}).captureTestOverrides(process.env) });
console.log("{}");
})();`, [point, direction || "", sid, tp, JSON.stringify(extra)]);
    const recs = F.records(sc).filter((x) => x.point === point);
    assert.strictEqual(recs.length, 1, "one record");
    assert.deepStrictEqual(scope3(recs[0]), []);
    assert.deepStrictEqual(recs[0].judged_in, { kind: "hook", name: "caller-x" });
    assert.strictEqual(recs[0].session_id, sid);
    assert.strictEqual(recs[0].llm ? recs[0].llm.executor : null, null);
  });
}
caseEnd();

// The migration cases: old lines carry "old":N so a duplicated or lost move is visible.
const oldLines = (n, tag) => Array.from({ length: n }, (_v, i) => JSON.stringify({ old: `${tag}${i}` })).join("\n") + "\n";
const APPEND = `require(${JSON.stringify(DR)}).appendDecision({ version: 2, record_type: "decision", point: "complexity-judge", ticket: null, mark: process.argv[2] });
console.log("{}");`;
const lines = (p) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean) : []);

caseBegin("log-migration", "hooks/lib/temporary-migrations/jev-decision-log-rename.js");
test("only the old .log and .log.1: both move to .jsonl / .jsonl.1, then the record is appended", () => {
  const sc = F.scene(ROOT, "mig-old");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  fs.writeFileSync(sc.oldLog, oldLines(2, "b"));
  fs.writeFileSync(`${sc.oldLog}.1`, oldLines(1, "r"));
  child(sc, APPEND, ["m1"]);
  assert.ok(!fs.existsSync(sc.oldLog) && !fs.existsSync(`${sc.oldLog}.1`), "no old file remains");
  assert.deepStrictEqual(lines(`${sc.log}.1`), [JSON.stringify({ old: "r0" })]);
  const base = lines(sc.log);
  assert.deepStrictEqual(base.slice(0, 2), [JSON.stringify({ old: "b0" }), JSON.stringify({ old: "b1" })]);
  assert.strictEqual(base.length, 3);
  assert.strictEqual(JSON.parse(base[2]).mark, "m1");
});
test("both names present: the old file is untouched, the new one gets the record", () => {
  const sc = F.scene(ROOT, "mig-both");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  fs.writeFileSync(sc.oldLog, oldLines(2, "o"));
  fs.writeFileSync(sc.log, oldLines(1, "n"));
  child(sc, APPEND, ["m2"]);
  assert.strictEqual(fs.readFileSync(sc.oldLog, "utf8"), oldLines(2, "o"));
  assert.deepStrictEqual(lines(sc.log).map((l) => JSON.parse(l).old || JSON.parse(l).mark), ["n0", "m2"]);
});
test("appendDecisionOnce migrates before the dedupe scan: a record only in the old log dedupes", () => {
  const sc = F.scene(ROOT, "mig-once");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  const rec = { version: 2, record_type: "decision", point: "complexity-judge", ticket: "0123456789abcdef" };
  fs.writeFileSync(sc.oldLog, JSON.stringify(rec) + "\n");
  const o = child(sc, `console.log(JSON.stringify(require(${JSON.stringify(DR)}).appendDecisionOnce(JSON.parse(process.argv[2]))));`, [JSON.stringify(rec)]);
  assert.strictEqual(o.deduped, true, JSON.stringify(o));
  assert.strictEqual(lines(sc.log).length, 1);
});
test("two processes appending at once: the old lines move exactly once", async () => {
  const sc = F.scene(ROOT, "mig-race");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  fs.writeFileSync(sc.oldLog, oldLines(3, "x"));
  const one = (mark) => new Promise((resolve) => {
    const c = spawn(process.execPath, ["-e", APPEND, "--", "eval", mark], { cwd: sc.cwd, env: F.envOf(sc, mock), stdio: "ignore" });
    c.on("exit", (code) => resolve(code));
  });
  const codes = await Promise.all([one("p1"), one("p2")]);
  assert.deepStrictEqual(codes, [0, 0]);
  const all = lines(sc.log).map((l) => JSON.parse(l));
  for (const t of ["x0", "x1", "x2"]) assert.strictEqual(all.filter((o) => o.old === t).length, 1, `${t} once`);
  assert.deepStrictEqual(all.filter((o) => o.mark).map((o) => o.mark).sort(), ["p1", "p2"]);
  assert.ok(!fs.existsSync(sc.oldLog), "no old file remains");
});
test("migration lock held by a live holder: nothing moves until it is released, then the move completes", async () => {
  const sc = F.scene(ROOT, "mig-lock");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  fs.writeFileSync(sc.oldLog, oldLines(1, "k"));
  const lock = `${sc.log}.migrate.lock`;
  fs.writeFileSync(lock, `${process.pid}.held`);
  const c = spawn(process.execPath, ["-e", APPEND, "--", "eval", "after-lock"], { cwd: sc.cwd, env: F.envOf(sc, mock), stdio: "ignore" });
  const done = new Promise((resolve) => c.on("exit", resolve));
  await new Promise((r) => setTimeout(r, 800));
  assert.ok(fs.existsSync(sc.oldLog), "the old file is not moved while another process holds the migration lock");
  fs.unlinkSync(lock);
  assert.strictEqual(await done, 0);
  assert.ok(!fs.existsSync(sc.oldLog), "moved once the lock was released");
  assert.deepStrictEqual(lines(sc.log).map((l) => JSON.parse(l).old || JSON.parse(l).mark), ["k0", "after-lock"]);
});
test("JEV=off: recordShadow writes nothing and the old log stays", () => {
  const sc = F.scene(ROOT, "mig-off");
  fs.mkdirSync(path.dirname(sc.oldLog), { recursive: true });
  fs.writeFileSync(sc.oldLog, oldLines(1, "f"));
  child(sc, `const r = require(${JSON.stringify(BROKER)}).recordShadow({ point: "complexity-judge", sessionId: process.argv[2], toolUseId: "toolu_off",
  llmText: "SIGNALS: S1-multi-file", toolInput: {}, step: "detail" });
console.log(JSON.stringify({ r }));`, [F.newSid()], { JEV: "off" });
  assert.ok(!fs.existsSync(sc.log), "no jev-decisions.jsonl");
  assert.strictEqual(fs.readFileSync(sc.oldLog, "utf8"), oldLines(1, "f"));
});
caseEnd();

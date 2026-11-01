#!/usr/bin/env node
// tests/hooks/feature-2461-wait-on-invoke.js
// Tests: bin/workflow/lib/next-step/wait-on-invoke.js, bin/workflow/lib/next-step/wait-on-invoke-child.js, bin/workflow/lib/next-step/emit.js, hooks/lib/turn-generation.js, hooks/lib/prompt-turn-id.js
// Tags: TL2, hooks, bin, jev, next-step, wait-on-invoke, continuation, turn-generation, trusted-transcript-path, path-traversal, cache, spawn-spy, mock-server, scope:issue-specific, pwsh-not-required
// #2461 Step 3: on ACTION=invoke with JEV on and a prompt-turn.json that names the transcript,
// next-step asks Jev once per session x step x turn (through a 3000 ms child) and adds
// JEV_ADVICE=wait-on-invoke plus a fixed JEV_ADVICE_REASON only on a confident yes; a step
// already advised in an earlier turn is never advised again; --jev-cache-only reads the cache.
// TL3 gap: the main conversation reading JEV_ADVICE and ending its turn instead of invoking the
// next skill. Mitigation: the CLAUDE.md workflow line; the real next-step CLI runs here.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2461wi-"));
const mock = F.startMock(path.join(ROOT, "mock"));
after(() => {
  mock.stop();
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const CHILD = "wait-on-invoke-child.js";
const ASKED = [F.U("please do the research"), F.A(F.T("Before I start: should the report include archived issues? MARKER-5521"))];

// started(name, entries) -> {sc, sid, tp}: research is current (ACTION=invoke) and one prompt turn
// names the transcript (entries null = no prompt turn at all).
function started(name, entries = ASKED) {
  const sc = F.scene(ROOT, name);
  const sid = F.newSid();
  F.seedStarted(sc, sid);
  let tp = null;
  if (entries) {
    tp = F.writeTranscript(sc, "t", entries);
    const turn = F.promptTurn(sc, sid, tp);
    assert.ok(turn && turn.transcript_path, `premise: prompt-turn.json names the transcript (got ${JSON.stringify(turn)})`);
  }
  return { sc, sid, tp };
}
const ns = (s, args = [], extra = {}) => F.nextStep(s.sc, mock, s.sid, args, Object.assign(F.spyEnv(s.sc), extra));
const advice = (o) => ({ advice: o.kv("JEV_ADVICE"), reason: o.kv("JEV_ADVICE_REASON") });
const childCalls = (s) => F.calledScript(s.sc, CHILD).length;
const NONE = { advice: "<none>", reason: "<none>" };

caseBegin("advice-on-confident-yes", "bin/workflow/lib/next-step/wait-on-invoke.js");
test("asked-user above threshold: ACTION=invoke kept, JEV_ADVICE=wait-on-invoke and a fixed reason added", () => {
  const s = started("yes");
  mock.conv(0.02, { "asked-user": 0.97 });
  const o = ns(s);
  assert.strictEqual(o.status, 0, o.stderr);
  assert.strictEqual(o.kv("ACTION"), "invoke");
  assert.strictEqual(o.kv("JEV_ADVICE"), "wait-on-invoke");
  assert.ok(/^'.+'$/.test(o.kv("JEV_ADVICE_REASON")), `quoted non-empty reason (got ${o.kv("JEV_ADVICE_REASON")})`);
  assert.ok(!o.stdout.includes("MARKER-5521"), "the reason never echoes the transcript");
  assert.strictEqual(o.all("JEV_ADVICE").length, 1);
  assert.strictEqual(mock.count("models"), 0, "no probe");
  assert.strictEqual(childCalls(s), 1, "one child");
  const rec = F.records(s.sc).find((r) => r.point === "continuation");
  assert.ok(rec, "a continuation record");
  assert.deepStrictEqual(rec.judged_in, { kind: "cli", name: "next-step" });
  assert.strictEqual(rec.final.direction, "wait-on-invoke");
  assert.strictEqual(rec.final.intervene, true);
  assert.strictEqual(rec.session_id, s.sid);
});
test("the reason is the key's fixed text: same key on another transcript gives the same reason, another key a different one", () => {
  mock.conv(0.02, { "asked-user": 0.97 });
  const a = advice(ns(started("fixed-a")));
  mock.conv(0.02, { "asked-user": 0.97 });
  const b = advice(ns(started("fixed-b", [F.U("go"), F.A(F.T("Which database should I use? OTHER-TEXT"))])));
  mock.conv(0.02, { "user-said-wait": 0.97 });
  const c = advice(ns(started("fixed-c", [F.U("wait for me before you continue"), F.A(F.T("Understood."))])));
  assert.strictEqual(a.advice, "wait-on-invoke");
  assert.deepStrictEqual(a, b);
  assert.strictEqual(c.advice, "wait-on-invoke");
  assert.notStrictEqual(c.reason, a.reason);
});
for (const [name, mode] of [["below-threshold", { echo: true, defaultP: 0.85 }], ["confident-no", { echo: true, defaultP: 0.02 }], ["badjson", { systemone: "badjson" }], ["http500", { systemone: "http:500" }]]) {
  test(`${name}: no advice and the 4-line output equals the JEV=off output`, () => {
    const s = started(`none-${name}`);
    mock.mode(Object.assign({ capture: true }, mode));
    const o = ns(s);
    assert.strictEqual(o.status, 0, o.stderr);
    assert.deepStrictEqual(advice(o), NONE);
    const off = ns(s, [], { JEV: "off" });
    assert.strictEqual(o.stdout, off.stdout);
  });
}
test("Jev slower than the child's 3000 ms budget: no advice, next-step still returns promptly", () => {
  const s = started("slow");
  mock.mode({ systemone: "slow", delayMs: 8000 });
  const o = ns(s);
  assert.strictEqual(o.kv("ACTION"), "invoke");
  assert.deepStrictEqual(advice(o), NONE);
  assert.ok(o.ms < 6500, `bounded by the child timeout (took ${o.ms} ms)`);
});
caseEnd();

caseBegin("cache-per-turn", "bin/workflow/lib/next-step/wait-on-invoke.js");
test("same turn: the cached verdict is returned without a second query", () => {
  const s = started("cache");
  mock.conv(0.02, { "asked-user": 0.97 });
  const first = advice(ns(s));
  assert.strictEqual(first.advice, "wait-on-invoke");
  assert.ok(F.readJson(F.controlFile(s.sc, s.sid, "wait-on-invoke.json")), "wait-on-invoke.json written");
  mock.conv(0.02);
  const second = advice(ns(s));
  assert.deepStrictEqual(second, first);
  assert.strictEqual(mock.count("systemone"), 0, "no second query");
});
test("same turn, cached no: still no advice and no query", () => {
  const s = started("cache-no");
  mock.conv(0.02);
  assert.deepStrictEqual(advice(ns(s)), NONE);
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.deepStrictEqual(advice(ns(s)), NONE);
  assert.strictEqual(mock.count("systemone"), 0);
});
test("a step already advised in an earlier turn: no advice and Jev is not asked in the new turn", () => {
  const s = started("earlier");
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.strictEqual(advice(ns(s)).advice, "wait-on-invoke");
  F.promptTurn(s.sc, s.sid, s.tp);
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.deepStrictEqual(advice(ns(s)), NONE);
  assert.strictEqual(mock.count("systemone"), 0);
});
test("cached no, then a new turn: Jev is asked again and can advise", () => {
  const s = started("cache-no-new-turn");
  mock.conv(0.02);
  assert.deepStrictEqual(advice(ns(s)), NONE);
  F.promptTurn(s.sc, s.sid, s.tp);
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.strictEqual(advice(ns(s)).advice, "wait-on-invoke");
  assert.strictEqual(mock.count("systemone"), 1);
});
test("advised, then the step advances: the new step is asked and advised", () => {
  const s = started("next-step-advances");
  mock.conv(0.02, { "asked-user": 0.97 });
  const first = ns(s);
  assert.strictEqual(advice(first).advice, "wait-on-invoke");
  F.markSteps(s.sc, s.sid, [["research", "skipped"]]);
  mock.conv(0.02, { "asked-user": 0.97 });
  const o = ns(s);
  assert.strictEqual(o.kv("ACTION"), "invoke");
  assert.notStrictEqual(o.kv("NEXT_SKILL"), first.kv("NEXT_SKILL"), "premise: the step advanced");
  assert.strictEqual(advice(o).advice, "wait-on-invoke");
  assert.strictEqual(mock.count("systemone"), 1);
});
test("corrupt wait-on-invoke.json is treated as absent: Jev is asked and the advice given", () => {
  const s = started("corrupt");
  F.writeControl(s.sc, s.sid, "wait-on-invoke.json", "{not json");
  mock.conv(0.02, { "asked-user": 0.97 });
  assert.strictEqual(advice(ns(s)).advice, "wait-on-invoke");
  assert.strictEqual(mock.count("systemone"), 1);
});
caseEnd();

caseBegin("cache-only-and-no-spawn", "bin/workflow/lib/next-step/wait-on-invoke.js");
test("--jev-cache-only on an uncached turn: no child, no query, no advice", () => {
  const s = started("co-miss");
  mock.conv(0.02, { "asked-user": 0.97 });
  const o = ns(s, ["--jev-cache-only"]);
  assert.strictEqual(o.kv("ACTION"), "invoke");
  assert.deepStrictEqual(advice(o), NONE);
  assert.strictEqual(childCalls(s), 0);
  assert.strictEqual(mock.count("systemone"), 0);
});
test("--jev-cache-only on a cached turn: the cached advice, still no child", () => {
  const s = started("co-hit");
  mock.conv(0.02, { "asked-user": 0.97 });
  const first = advice(ns(s));
  const before = childCalls(s);
  mock.conv(0.02);
  const o = ns(s, ["--jev-cache-only"]);
  assert.deepStrictEqual(advice(o), first);
  assert.strictEqual(childCalls(s), before);
});
const NO_SPAWN = [
  ["JEV=off", (s) => ns(s, [], { JEV: "off" })],
  ["no prompt-turn.json", null],
  ["prompt-turn.json without transcript_path", (s) => {
    F.writeControl(s.sc, s.sid, "prompt-turn.json", JSON.stringify({ turn_id: "0123456789abcdef0123456789abcdef", created_at: new Date().toISOString() }));
    return ns(s);
  }],
  ["malformed prompt-turn.json", (s) => { F.writeControl(s.sc, s.sid, "prompt-turn.json", "{oops"); return ns(s); }],
];
for (const [name, act] of NO_SPAWN) {
  test(`${name}: the child is never spawned and no advice is printed`, () => {
    const s = started(`ns-${name.replace(/[^a-z]+/gi, "-")}`, act ? ASKED : null);
    mock.conv(0.02, { "asked-user": 0.97 });
    if (act && name !== "JEV=off") fs.rmSync(F.controlFile(s.sc, s.sid, "prompt-turn.json"), { force: true });
    const o = act ? act(s) : ns(s);
    assert.strictEqual(o.kv("ACTION"), "invoke");
    assert.deepStrictEqual(advice(o), NONE);
    assert.strictEqual(childCalls(s), 0);
    assert.strictEqual(mock.count("systemone"), 0);
  });
}
const STEPS = require(F.lib("hooks/workflow-state/state-io/core.js")).VALID_STEPS;
const LATER = STEPS.slice(STEPS.indexOf("clarify_intent") + 1);
for (const [want, seed] of [["done", (s) => F.markSteps(s.sc, s.sid, LATER.map((st) => [st, "skipped"]))], ["abort", (s) => F.markSteps(s.sc, s.sid, [["branching_complete", "complete"]])]]) {
  test(`ACTION=${want}: no child, no query, no advice`, () => {
    const s = started(`ns-action-${want}`);
    seed(s);
    mock.conv(0.02, { "asked-user": 0.97 });
    const o = ns(s);
    assert.strictEqual(o.kv("ACTION"), want, "premise");
    assert.deepStrictEqual(advice(o), NONE);
    assert.strictEqual(childCalls(s), 0);
    assert.strictEqual(mock.count("systemone"), 0);
  });
}
caseEnd();

caseBegin("turn-generation", "hooks/lib/turn-generation.js");
const TG_CODE = `const tg = require(${JSON.stringify(F.lib("hooks/lib/turn-generation.js"))});
console.log(JSON.stringify({ a: tg.readTurnGeneration(process.argv[2]), b: tg.readTurnGeneration(process.argv[3]) }));`;
test("prompt-turn.json carries transcript_path; readTurnGeneration returns {turnId, transcriptPath} or null", () => {
  const s = started("tg");
  const turn = F.readJson(F.controlFile(s.sc, s.sid, "prompt-turn.json"));
  assert.strictEqual(F.fwd(turn.transcript_path), s.tp);
  assert.ok(s.tp.startsWith(`${F.fwd(s.sc.claudeCfg)}/projects/`), `premise: the transcript is under <CLAUDE_CONFIG_DIR>/projects (got ${s.tp})`);
  const code = TG_CODE;
  const o = F.nodeEval(s.sc, null, code, [s.sid, F.newSid()]);
  assert.strictEqual(o.status, 0, o.stderr);
  assert.strictEqual(o.json.a.turnId, turn.turn_id);
  assert.strictEqual(F.fwd(o.json.a.transcriptPath), s.tp);
  assert.strictEqual(o.json.b, null);
  F.writeControl(s.sc, s.sid, "prompt-turn.json", "{oops");
  const bad = F.nodeEval(s.sc, null, code, [s.sid, s.sid]);
  assert.strictEqual(bad.json.a, null, "malformed -> null");
});
// An untrusted recorded transcript path is treated as absent: readTurnGeneration -> null.
const UNTRUSTED = [
  ["a non-.jsonl file under projects/", (sc) => {
    const p = path.join(F.transcriptDir(sc), "t.txt");
    fs.writeFileSync(p, "{}\n");
    return F.fwd(p);
  }],
  ["a .jsonl outside projects/", (sc) => {
    const p = path.join(sc.io, "t.jsonl");
    fs.writeFileSync(p, "{}\n");
    return F.fwd(p);
  }],
  ["a .. escape out of projects/", (sc) => {
    fs.writeFileSync(path.join(sc.claudeCfg, "escape.jsonl"), "{}\n");
    return `${F.fwd(F.transcriptDir(sc))}/../../escape.jsonl`;
  }],
  ["the projects/ root itself named .jsonl", (sc) => `${F.fwd(sc.claudeCfg)}/projects/../projects.jsonl`],
];
for (const [name, mk] of UNTRUSTED) {
  test(`${name}: readTurnGeneration returns null`, () => {
    const s = started(`tg-untrusted-${name.replace(/[^a-z]+/gi, "-")}`);
    const tp = mk(s.sc);
    const turn = F.promptTurn(s.sc, s.sid, tp);
    assert.strictEqual(turn && turn.transcript_path, tp, "premise: prompt-turn.json records the untrusted path");
    const o = F.nodeEval(s.sc, null, TG_CODE, [s.sid, F.newSid()]);
    assert.strictEqual(o.status, 0, o.stderr);
    assert.strictEqual(o.json.a, null);
  });
}
test("an untrusted transcript path: next-step neither spawns the child nor asks Jev", () => {
  const s = started("tg-untrusted-ns");
  const p = path.join(s.sc.io, "t.jsonl");
  fs.writeFileSync(p, fs.readFileSync(s.tp));
  F.promptTurn(s.sc, s.sid, F.fwd(p));
  mock.conv(0.02, { "asked-user": 0.97 });
  const o = ns(s);
  assert.strictEqual(o.kv("ACTION"), "invoke");
  assert.deepStrictEqual(advice(o), NONE);
  assert.strictEqual(childCalls(s), 0);
  assert.strictEqual(mock.count("systemone"), 0);
});
caseEnd();

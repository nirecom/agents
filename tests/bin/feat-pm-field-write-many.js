"use strict";
// tests/bin/feat-pm-field-write-many.js
// Tests: bin/lib/pm-field/write.js, bin/lib/project-board/resolve.js, hooks/pm-session/ownership.js
// Tags: TL2, scope:issue-specific, pm-session, pm-field, forge, gh, budget, issue-3152
// #3152: the PM field write of one hook run is one alias mutation (writeMany), split ALIAS_CHUNK items per
// call; each alias settles ok / failed / unknown, and the writer re-reads only the unknown ones. Every gh
// call goes through an injected spawnSync (no process spawned); resolveBoard takes the same injection.
// TL3 gap: GitHub's real answer to an aliased mutation (partial errors, rate limits) is not observed; the
// fake below answers the shape the plan names (data.m<i>, errors[].path[0]).

const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

const W = () => P.load("bin/lib/pm-field/write.js");
const ref = (n) => ({ number: n, repo: "o/r" });
const key = (r) => `${r.repo}#${r.number}`;
const itemOf = (n) => `PVTI_w_${n}`;
const card = (n) => ({ ok: true, itemId: itemOf(n), projectId: "PVT_w", fieldId: "PVTF_w" });
const cardsFor = (ns) => Object.fromEntries(ns.map((n) => [key(ref(n)), card(n)]));
const items = (ns, value = "PM-w") => ns.map((n) => ({ ref: ref(n), value }));
const SOON = () => Date.now() + 60000;

// aliasesOf(q, vars) -> [{alias, op, itemId, text}] of an aliased mutation; inline input or GraphQL variables.
function aliasesOf(q, vars) {
  const hits = [...q.matchAll(/\b(m\d+)\s*:\s*(updateProjectV2ItemFieldValue|clearProjectV2ItemFieldValue)\s*\(/g)];
  return hits.map((h, i) => {
    const seg = q.slice(h.index, i + 1 < hits.length ? hits[i + 1].index : q.length);
    const asVar = /input\s*:\s*\$(\w+)/.exec(seg);
    const input = asVar ? (vars || {})[asVar[1]] || {} : null;
    const pick = (name) => {
      if (input) return name === "text" ? (input.value || {}).text : input[name];
      const m = new RegExp(`${name}\\s*:\\s*(?:\\\\?"([^"\\\\]*)|\\$(\\w+))`).exec(seg);
      return m ? (m[1] !== undefined ? m[1] : (vars || {})[m[2]]) : undefined;
    };
    return { alias: h[1], op: h[2], itemId: pick("itemId"), text: pick("text") };
  });
}
// fakeGh({outcome, whole}) -> {spawnSync, calls}: outcome(itemId) is "ok" | "error" | "absent" (no data.m<i>);
// whole "kill" | "enoent" | "nodata" answers the whole call that way.
function fakeGh(o = {}) {
  const calls = [];
  const spawnSync = (cmd, args, opts) => {
    let body = {};
    try { body = JSON.parse(String((opts && opts.input) || "")); } catch (_) { body = {}; }
    const q = String(body.query || "");
    const aliases = aliasesOf(q, body.variables);
    calls.push({ args: [].concat(args || []), q, aliases, timeout: opts && opts.timeout });
    if (o.whole === "kill") return { status: null, signal: "SIGTERM", error: Object.assign(new Error("spawnSync gh ETIMEDOUT"), { code: "ETIMEDOUT" }), stdout: "", stderr: "" };
    if (o.whole === "enoent") return { status: null, signal: null, error: Object.assign(new Error("spawnSync gh ENOENT"), { code: "ENOENT" }), stdout: "", stderr: "" };
    if (o.whole === "nodata") return { status: 1, signal: null, stdout: JSON.stringify({ errors: [{ message: "Something went wrong" }] }), stderr: "" };
    const data = {};
    const errors = [];
    for (const a of aliases) {
      const r = o.outcome ? o.outcome(a.itemId) : "ok";
      if (r === "ok") data[a.alias] = { projectV2Item: { id: a.itemId } };
      if (r === "error") { data[a.alias] = null; errors.push({ type: "FORBIDDEN", path: [a.alias], message: "denied" }); }
    }
    return { status: errors.length ? 1 : 0, signal: null, stdout: JSON.stringify(errors.length ? { data, errors } : { data }), stderr: "" };
  };
  return { spawnSync, calls, mutations: () => calls.filter((c) => /\bmutation\b/.test(c.q)) };
}
// pmField(gh, mutate?) -> createPmField over the fake, its cards seeded; writeMany asserted present.
function pmField(gh, ns, mutate = SOON()) {
  const io = W().createPmField({ deadlines: { mutate, reread: mutate }, spawnSync: gh.spawnSync });
  assert.strictEqual(typeof io.writeMany, "function", "createPmField(...).writeMany is missing (#3152)");
  assert.strictEqual(typeof io.seedCards, "function", "createPmField(...).seedCards is missing (#3152)");
  io.seedCards(cardsFor(ns));
  return io;
}
// outcomes(r, list) -> [{result, reason}] in item order, from an array or a map keyed "o/r#N".
function outcomes(r, list) {
  const arr = Array.isArray(r) ? r : Array.isArray(r && r.results) ? r.results : null;
  const map = arr ? null : (r && r.results) || r || {};
  return list.map((it, i) => {
    const x = arr ? arr[i] : map[key(it.ref)];
    return x ? { result: x.result, reason: x.reason } : { result: undefined };
  });
}
const results = (os) => os.map((o) => o.result);

caseBegin("pm-field-write-many-alias", "bin/lib/pm-field/write.js");
test("A1 one aliased mutation: update for a tag, clear for null, each on its seeded card", () => {
  const gh = fakeGh();
  const list = [{ ref: ref(31601), value: "PM-a" }, { ref: ref(31602), value: null }];
  const got = outcomes(pmField(gh, [31601, 31602]).writeMany(list), list);
  assert.deepStrictEqual(results(got), ["ok", "ok"], JSON.stringify(got));
  assert.strictEqual(gh.calls.length, 1, "one gh call for both items");
  const a = gh.calls[0].aliases;
  assert.deepStrictEqual(a.map((x) => [x.op, x.itemId]), [["updateProjectV2ItemFieldValue", itemOf(31601)], ["clearProjectV2ItemFieldValue", itemOf(31602)]], gh.calls[0].q);
  assert.strictEqual(a[0].text, "PM-a", gh.calls[0].q);
});
test("A2 ok, failed and unknown in one answer map to their items", () => {
  const out = { [itemOf(31611)]: "ok", [itemOf(31612)]: "error", [itemOf(31613)]: "absent" };
  const gh = fakeGh({ outcome: (id) => out[id] });
  const list = items([31611, 31612, 31613]);
  const got = outcomes(pmField(gh, [31611, 31612, 31613]).writeMany(list), list);
  assert.deepStrictEqual(results(got), ["ok", "failed", "unknown"], JSON.stringify(got));
});
test("A3 a killed call or an answer without data leaves every item unknown", () => {
  for (const whole of ["kill", "nodata"]) {
    const list = items([31621, 31622]);
    const got = outcomes(pmField(fakeGh({ whole }), [31621, 31622]).writeMany(list), list);
    assert.deepStrictEqual(results(got), ["unknown", "unknown"], `${whole}: ${JSON.stringify(got)}`);
  }
});
test("A4 a gh that cannot start fails every item spawn-failed; a spent window fails them budget-exhausted with no call", () => {
  const list = items([31631, 31632]);
  const enoent = outcomes(pmField(fakeGh({ whole: "enoent" }), [31631, 31632]).writeMany(list), list);
  assert.deepStrictEqual(enoent, [{ result: "failed", reason: "spawn-failed" }, { result: "failed", reason: "spawn-failed" }]);
  const gh = fakeGh();
  const spent = outcomes(pmField(gh, [31631, 31632], Date.now() - 1).writeMany(list), list);
  assert.deepStrictEqual(spent, [{ result: "failed", reason: "budget-exhausted" }, { result: "failed", reason: "budget-exhausted" }]);
  assert.strictEqual(gh.calls.length, 0, "a spent window calls no gh");
});
test("A5 an item whose card has no project or field id fails no-card and is not sent", () => {
  const gh = fakeGh();
  const io = pmField(gh, [31641]);
  io.seedCards({ [key(ref(31642))]: { ok: true, itemId: itemOf(31642), projectId: null, fieldId: null } });
  const list = items([31641, 31642]);
  const got = outcomes(io.writeMany(list), list);
  assert.deepStrictEqual(got, [{ result: "ok", reason: undefined }, { result: "failed", reason: "no-card" }]);
  assert.deepStrictEqual([].concat(...gh.calls.map((c) => c.aliases.map((x) => x.itemId))), [itemOf(31641)]);
});
test("A6 the mutation's gh timeout stays inside the mutate deadline", () => {
  const gh = fakeGh();
  const before = Date.now();
  const deadline = before + 1500;
  const list = items([31651]);
  pmField(gh, [31651], deadline).writeMany(list);
  assert.strictEqual(gh.calls.length, 1);
  assert.ok(Number.isFinite(gh.calls[0].timeout) && gh.calls[0].timeout <= deadline - before, `timeout ${gh.calls[0].timeout} > ${deadline - before}`);
});
caseEnd();

caseBegin("pm-field-write-many-chunk", "bin/lib/pm-field/write.js");
test("A7 ALIAS_CHUNK is 20; 45 items go in ceil(45 / ALIAS_CHUNK) mutations of at most ALIAS_CHUNK aliases", () => {
  const C = W().ALIAS_CHUNK;
  assert.strictEqual(C, 20, "write.js exports ALIAS_CHUNK = 20");
  const ns = Array.from({ length: 45 }, (_, i) => 31700 + i);
  const gh = fakeGh();
  const list = items(ns);
  const got = outcomes(pmField(gh, ns).writeMany(list), list);
  assert.ok(results(got).every((r) => r === "ok"), JSON.stringify(got));
  assert.strictEqual(gh.calls.length, Math.ceil(45 / C));
  for (const c of gh.calls) assert.ok(c.aliases.length <= C, `${c.aliases.length} aliases in one call`);
  assert.deepStrictEqual([].concat(...gh.calls.map((c) => c.aliases.map((x) => x.itemId))).sort(), ns.map(itemOf).sort());
});
test("A8 the deadline runs out during the first chunk: the second chunk is not sent and fails budget-exhausted", () => {
  const C = W().ALIAS_CHUNK;
  const ns = Array.from({ length: 25 }, (_, i) => 31750 + i);
  const gh = fakeGh();
  const savedNow = Date.now;
  const deadline = savedNow() + 5000;
  // The first gh call takes the clock past the mutate deadline (no real wait).
  const slowGh = { spawnSync: (...a) => { const r = gh.spawnSync(...a); Date.now = () => savedNow() + 60000; return r; } };
  const list = items(ns);
  let got;
  try {
    got = outcomes(pmField(slowGh, ns, deadline).writeMany(list), list);
  } finally { Date.now = savedNow; }
  assert.strictEqual(gh.calls.length, 1, `a gh call after the deadline: ${gh.calls.length} calls`);
  assert.deepStrictEqual(results(got.slice(0, C)), Array(C).fill("ok"), JSON.stringify(got));
  assert.deepStrictEqual(got.slice(C), Array(25 - C).fill({ result: "failed", reason: "budget-exhausted" }), JSON.stringify(got));
});
test("A9 an empty list calls no gh and returns no result", () => {
  const gh = fakeGh();
  const r = pmField(gh, []).writeMany([]);
  const size = Array.isArray(r) ? r.length : Array.isArray(r && r.results) ? r.results.length : Object.keys((r && r.results) || r || {}).length;
  assert.strictEqual(size, 0, JSON.stringify(r));
  assert.strictEqual(gh.calls.length, 0);
});
caseEnd();

caseBegin("project-board-resolve-spawn-injected", "bin/lib/project-board/resolve.js");
test("B1 resolveBoard runs the resolver through the injected spawnSync with its timeout", () => {
  const seen = [];
  const spawnSync = (cmd, args, opts) => {
    seen.push(opts && opts.timeout);
    return { status: 0, signal: null, stdout: "status=resolved\nowner=o\nnumber=7\nproject_id=PVT_rb\n", stderr: "" };
  };
  const b = P.load("bin/lib/project-board/resolve.js").resolveBoard("o/r", { timeoutMs: 1234, spawnSync });
  assert.strictEqual(seen.length, 1, `the injected spawnSync was not used: ${JSON.stringify(b)}`);
  assert.ok(seen[0] <= 1234, `timeout ${seen[0]}`);
  assert.deepStrictEqual([b.status, b.number, b.projectId], ["resolved", 7, "PVT_rb"]);
});
caseEnd();

caseBegin("pm-writer-rereads-only-unknown", "hooks/pm-session/ownership.js");
let n = 0;
const sid = () => P.uuid(0x31520100 + (++n));
// run(outcome, read) -> the writer's result for /pm-add of two issues over a pmField whose writeMany answers
// outcome(number) per item; reads lists the refs of every io.read.
function run(outcome, read) {
  G.setMap({});
  const s = sid();
  const tag = `PM-wm${n}`;
  const a = 31800 + n * 10;
  P.seedPm(s, P.pm({ tag, issues: [a] }));
  const before = P.readPm(s);
  const reads = [];
  const singles = [];
  const batches = [];
  const io = {
    write: (r) => { singles.push(key(r)); return { result: "ok" }; },
    writeMany: (list) => { batches.push(list.map((it) => key(it.ref))); return list.map((it) => ({ ref: it.ref, value: it.value, result: outcome(it.ref.number - a) })); },
    seedCards: () => {},
    read: (refs) => { reads.push(refs.map(key)); return read(refs, tag); },
  };
  const r = X.write(s, P.wrapped("pm-add", `#${a + 1} #${a + 2} reason`), { pmField: io });
  return { r, s, a, before, reads, singles, batches };
}
const valuesOf = (refs, v) => ({ ok: true, values: Object.fromEntries(refs.map((x) => [key(x), v])) });
test("R1 one ok and one unknown: only the unknown one is read back; it landed, so the add is accepted", () => {
  const x = run((i) => (i === 2 ? "unknown" : "ok"), (refs, tag) => valuesOf(refs, tag));
  assert.ok(!x.r.block && !x.r.threw, JSON.stringify(x.r));
  assert.deepStrictEqual(x.batches, [[`o/r#${x.a + 1}`, `o/r#${x.a + 2}`]], "both fields in one writeMany");
  assert.deepStrictEqual(x.singles, [], "no per-issue write");
  assert.deepStrictEqual(x.reads, [[`o/r#${x.a + 2}`]]);
  assert.strictEqual(P.readPm(x.s).issues.length, 3, JSON.stringify(P.readPm(x.s)));
});
test("R2 every item ok: no read back", () => {
  const x = run(() => "ok", () => assert.fail("read after an all-ok write"));
  assert.ok(!x.r.block && !x.r.threw, JSON.stringify(x.r));
  assert.deepStrictEqual(x.reads, []);
});
test("R3 an unknown item that did not land refuses; the PM state is unchanged", () => {
  const x = run((i) => (i === 1 ? "unknown" : "ok"), (refs) => valuesOf(refs, null));
  assert.ok(typeof x.r.block === "string" && /pm-field/i.test(x.r.block), JSON.stringify(x.r));
  assert.deepStrictEqual(x.reads, [[`o/r#${x.a + 1}`]]);
  assert.deepStrictEqual(P.readPm(x.s), x.before);
});
caseEnd();

caseBegin("pm-field-write-many-edges", "bin/lib/pm-field/write.js");
const EXHAUSTED = { result: "failed", reason: "budget-exhausted" };
const sentIds = (gh) => [].concat(...gh.calls.map((c) => c.aliases.map((x) => x.itemId)));
test("A10 the mutate deadline not yet passed but less left than minCallMs: budget-exhausted with no call", () => {
  const ns = [31901, 31902];
  const list = items(ns);
  const at = (gh, mutate) => {
    const io = W().createPmField({ deadlines: { mutate, reread: mutate }, spawnSync: gh.spawnSync, minCallMs: 400 });
    io.seedCards(cardsFor(ns));
    return outcomes(io.writeMany(list), list);
  };
  const short = fakeGh();
  assert.deepStrictEqual(at(short, Date.now() + 300), [EXHAUSTED, EXHAUSTED]);
  assert.strictEqual(short.calls.length, 0, "gh ran with less than minCallMs left");
  const roomy = fakeGh();
  assert.deepStrictEqual(results(at(roomy, SOON())), ["ok", "ok"], "the same minCallMs with room left still sends");
  assert.strictEqual(roomy.calls.length, 1);
});
test("A11 an ambiguous, a truncated or an unseeded card fails with its own reason and stays out of the mutation", () => {
  const gh = fakeGh();
  const io = pmField(gh, [31911]);
  io.seedCards({ [key(ref(31912))]: { ok: false, reason: "pm-field-ambiguous" }, [key(ref(31913))]: { ok: false, reason: "pm-field-truncated" } });
  const list = items([31911, 31912, 31913, 31914]);
  const got = outcomes(io.writeMany(list), list);
  assert.deepStrictEqual(got, [
    { result: "ok", reason: undefined },
    { result: "failed", reason: "pm-field-ambiguous" },
    { result: "failed", reason: "pm-field-truncated" },
    { result: "failed", reason: "no-card" },
  ]);
  assert.deepStrictEqual(sentIds(gh), [itemOf(31911)]);
});
test("A12 an alias error with no type gives its message as the reason; with neither, mutation-error", () => {
  const calls = [];
  const spawnSync = (cmd, args, opts) => {
    const body = JSON.parse(String(opts.input));
    const a = aliasesOf(body.query, body.variables);
    calls.push(a);
    const data = Object.fromEntries(a.map((x) => [x.alias, null]));
    return { status: 1, signal: null, stdout: JSON.stringify({ data, errors: [{ path: [a[0].alias], message: "denied here" }, { path: [a[1].alias] }] }), stderr: "" };
  };
  const list = items([31921, 31922]);
  const got = outcomes(pmField({ spawnSync }, [31921, 31922]).writeMany(list), list);
  assert.strictEqual(calls.length, 1);
  assert.deepStrictEqual(got, [{ result: "failed", reason: "denied here" }, { result: "failed", reason: "mutation-error" }]);
});
test("A13 a spawnSync that throws fails every item spawn-failed", () => {
  let n31 = 0;
  const spawnSync = () => { n31++; throw new Error("spawn EPERM"); };
  const list = items([31931, 31932]);
  const got = outcomes(pmField({ spawnSync }, [31931, 31932]).writeMany(list), list);
  assert.strictEqual(n31, 1);
  assert.deepStrictEqual(got, [{ result: "failed", reason: "spawn-failed" }, { result: "failed", reason: "spawn-failed" }]);
});
caseEnd();

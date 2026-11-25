"use strict";
// Tests: bin/lib/pm-field/write.js, bin/lib/pm-field/read.js, hooks/pm-session/writer.js
// Tags: TL2, scope:common, pm-session, pm-field, issue-2942
// #2942 S6: PM field write + gh timeout, the re-read settling an unknown write, the batched read (fake gh).
// TL3 gap (what this test does NOT catch):
// - the real `gh project item-edit` against GitHub, and ensure-board-card.sh resolving a real card;
// - the real 10 s UserPromptSubmit hook kill while gh is still writing.
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const P = require("../lib/pm-state-fixture");
// The 2941 writer fixture owns the fake-gh env (G, restored by its after()) and a checkout whose origin is o/r.
const restore = isolate();
const { G, home } = require("../hooks/feature-2941-pm-writer/fixture");
after(() => { restore(); });
// Assumed: writePmField(ref, value|null, {timeoutMs, resolveCard}) -> {result:"ok"|"failed"|"unknown", reason?};
// resolveCard(ref) -> {ok, itemId, projectId, fieldId} stands in for ensure-board-card.sh; null clears (--clear).
const W = P.load("bin/lib/pm-field/write.js");
// Assumed: readPmFields(refs, {timeoutMs}) -> {ok:true, values:{"o/r#N": tag|null}} | {ok:false, reason}; <=50 refs per gh call.
const R = P.load("bin/lib/pm-field/read.js");
const ref = (n) => ({ number: n, repo: "o/r" });
const item = (n) => `PVTI_o_r_${n}`;
const card = (r) => ({ ok: true, itemId: item(r.number), projectId: "PVT_1", fieldId: "PVTF_pm" });
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (_) { return false; } };

caseBegin("pm-field-write-and-timeout", "bin/lib/pm-field/write.js");
test("F1 a write sets the field with gh project item-edit --text and reports ok", () => {
  G.setPmStore({});
  const r = W.writePmField(ref(9101), "PM-f", { timeoutMs: 3500, resolveCard: card });
  assert.strictEqual(r.result, "ok", JSON.stringify(r));
  assert.strictEqual(G.pmStore()[item(9101)], "PM-f");
  assert.ok(G.queries().some((q) => q.startsWith("project item-edit") && q.includes("--text PM-f") && q.includes(`--id ${item(9101)}`)), G.queries().join("\n"));
});
test("F1 a null value clears the field with --clear", () => {
  G.setPmStore({ [item(9102)]: "PM-old" });
  const r = W.writePmField(ref(9102), null, { timeoutMs: 3500, resolveCard: card });
  assert.strictEqual(r.result, "ok", JSON.stringify(r));
  assert.strictEqual(G.pmStore()[item(9102)], null);
  assert.ok(G.queries().some((q) => q.startsWith("project item-edit") && q.includes("--clear")), G.queries().join("\n"));
});
test("F2 a gh edit that outlives the timeout is killed and reports unknown, within the budget", () => {
  G.setPmStore({});
  fs.rmSync(G.editPidFile, { force: true });
  G.editSleep(8000);
  const t0 = Date.now();
  let r;
  try { r = W.writePmField(ref(9103), "PM-slow", { timeoutMs: 700, resolveCard: card }); } finally { G.editSleep(null); }
  const ms = Date.now() - t0;
  assert.strictEqual(r.result, "unknown", JSON.stringify(r));
  assert.ok(ms < 4000, `the write waited for the hung gh (${ms} ms)`);
  // Windows: the bash shim's node grandchild may outlive the kill; assert the process only where it is the direct child.
  const pid = fs.existsSync(G.editPidFile) ? Number(fs.readFileSync(G.editPidFile, "utf8")) : 0;
  if (pid > 0 && process.platform !== "win32") assert.strictEqual(alive(pid), false, `gh child ${pid} still runs after the timeout`);
});
test("F3 a failing gh edit reports failed, not ok", () => {
  G.editMode("fail");
  let r;
  try { r = W.writePmField(ref(9104), "PM-x", { timeoutMs: 3500, resolveCard: card }); } finally { G.editMode(null); }
  assert.strictEqual(r.result, "failed", JSON.stringify(r));
});
test("F3 a card that cannot be resolved reports failed and runs no edit", () => {
  const before = G.calls();
  const r = W.writePmField(ref(9105), "PM-x", { timeoutMs: 3500, resolveCard: () => ({ ok: false, reason: "no-card" }) });
  assert.strictEqual(r.result, "failed", JSON.stringify(r));
  assert.strictEqual(G.queries().slice(before).filter((q) => q.startsWith("project item-edit")).length, 0);
});
caseEnd();

caseBegin("pm-field-batched-read", "bin/lib/pm-field/read.js");
test("D1 one GraphQL call reads every issue's value; an unset field reads null", () => {
  G.setMap({ "o/r#9201": { pm: "PM-a" }, "o/r#9202": {} });
  G.setPmStore({ [item(9203)]: "PM-b" });
  const before = G.calls();
  const r = R.readPmFields([ref(9201), ref(9202), ref(9203)], { timeoutMs: 1500 });
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(r.values, { "o/r#9201": "PM-a", "o/r#9202": null, "o/r#9203": "PM-b" });
  assert.strictEqual(G.calls() - before, 1);
});
test("D2 more than 50 refs are read in chunks of at most 50", () => {
  G.setMap({});
  const refs = Array.from({ length: 120 }, (_, i) => ref(9300 + i));
  const before = G.calls();
  const r = R.readPmFields(refs, { timeoutMs: 5000 });
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.strictEqual(Object.keys(r.values).length, 120);
  assert.strictEqual(G.calls() - before, 3);
});
test("D3 a forge failure reads as {ok:false, reason}, never as unset values", () => {
  G.mode("fail");
  let r;
  try { r = R.readPmFields([ref(9401)], { timeoutMs: 1500 }); } finally { G.mode(null); }
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.ok(r.reason, JSON.stringify(r));
});
test("D3 a read slower than its timeout reads as {ok:false}", () => {
  G.sleep(4000);
  let r;
  try { r = R.readPmFields([ref(9402)], { timeoutMs: 500 }); } finally { G.sleep(null); }
  assert.strictEqual(r.ok, false, JSON.stringify(r));
});
caseEnd();

// #3152: /pm-remove and /pm-rename read the PM values and the cards in one gh call, so the write needs no readCards.
// Assumed: readPmFieldsAndCards(refs, opts) -> {ok:true, values:{"o/r#N": tag|null}, cards:{"o/r#N": card}} | {ok:false, reason}.
caseBegin("pm-field-read-fields-and-cards", "bin/lib/pm-field/read.js");
test("D4 readPmFieldsAndCards answers readPmFields' values and readCards' cards from one gh call", () => {
  assert.strictEqual(typeof R.readPmFieldsAndCards, "function", "read.js does not export readPmFieldsAndCards (#3152)");
  G.setPmStore({ [item(9451)]: "PM-a" });
  G.setMap({ "o/r#9452": {}, "o/r#9453": { noCard: true } });
  const refs = [ref(9451), ref(9452), ref(9453)];
  const before = G.calls();
  const r = R.readPmFieldsAndCards(refs, { timeoutMs: 5000 });
  assert.strictEqual(G.calls() - before, 1, "one gh call for values and cards");
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(r.values, R.readPmFields(refs, { timeoutMs: 5000 }).values, JSON.stringify(r));
  assert.deepStrictEqual(r.cards || r.results, R.readCards(refs, { timeoutMs: 5000 }).results, JSON.stringify(r));
});
test("D4 a forge failure fails the combined read as a whole", () => {
  assert.strictEqual(typeof R.readPmFieldsAndCards, "function", "read.js does not export readPmFieldsAndCards (#3152)");
  G.mode("fail");
  let r;
  try { r = R.readPmFieldsAndCards([ref(9454)], { timeoutMs: 1500 }); } finally { G.mode(null); }
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.ok(r.reason, JSON.stringify(r));
});
caseEnd();

// #2942: an issue on several Projects whose pm values differ is pm-field-ambiguous (never the first value).
const path = require("node:path");
const LINKS = path.join(P.ROOT, "bin", "lib", "forge-issue-links.js");
const READ = path.join(P.ROOT, "bin", "lib", "pm-field", "read.js");
// freshRead(nodes) -> read.js over a batchedGraphql that hands nodes["o/r#N"] to the spec's readNode.
function freshRead(nodes) {
  const real = require(LINKS);
  const saved = require.cache[LINKS];
  const savedRead = require.cache[READ];
  delete require.cache[READ];
  const batchedGraphql = (refs, spec) => ({ ok: true, results: Object.fromEntries(refs.map((x) => { const k = real.refKey(x.repo, x.number); return [k, spec.readNode(nodes[k], k)]; })) });
  require.cache[LINKS] = Object.assign({}, saved, { exports: Object.assign({}, real, { batchedGraphql }) });
  try { return require(READ); } finally { require.cache[LINKS] = saved; require.cache[READ] = savedRead; }
}
const cardsOf = (n, pms, o = {}) => ({ number: n, repository: { nameWithOwner: "o/r" }, parent: o.parent || null,
  projectItems: { nodes: pms.map((pm, i) => ({ id: `I${n}-${i}`, pm: pm ? { text: pm } : null, project: { id: `P${i}`, field: o.noField ? null : { id: `F${i}` } } })) } });
caseBegin("pm-field-ambiguous-read", "bin/lib/pm-field/read.js");
test("M1 two Projects naming different PMs -> pmReadOf/readPmFields pm-field-ambiguous; pmOf not exported", () => {
  const node = cardsOf(9701, ["PM-a", "PM-b"]);
  assert.deepStrictEqual(R.pmReadOf(node), { ok: false, reason: "pm-field-ambiguous" });
  assert.strictEqual(R.pmOf, undefined, "pmOf must not be exported");
  const r = freshRead({ "o/r#9701": node }).readPmFields([ref(9701)]);
  assert.deepStrictEqual(r, { ok: false, reason: "pm-field-ambiguous" });
});
test("M1 the same tag on two Projects (any case) or one empty card reads that tag", () => {
  assert.deepStrictEqual(R.pmReadOf(cardsOf(9702, ["PM-a", "pm-A"])), { ok: true, pm: "PM-a" });
  assert.deepStrictEqual(R.pmReadOf(cardsOf(9703, ["PM-a", null])), { ok: true, pm: "PM-a" });
});
test("M2 an ancestor with differing values fails the chain read; two pm-field boards fail readCards", () => {
  const nodes = { "o/r#9711": cardsOf(9711, [null], { parent: cardsOf(9712, ["PM-a", "PM-b"]) }), "o/r#9713": cardsOf(9713, [null, null]) };
  const M = freshRead(nodes);
  assert.deepStrictEqual(M.readPmChains([ref(9711)]).results["o/r#9711"], { ok: false, reason: "pm-field-ambiguous" });
  assert.deepStrictEqual(M.readCards([ref(9713)]).results["o/r#9713"], { ok: false, reason: "pm-field-ambiguous" });
});
caseEnd();
caseBegin("pm-field-ambiguous-write", "bin/lib/pm-field/write.js");
test("M3 an ambiguous card makes the write fail with pm-field-ambiguous and runs no edit", () => {
  const orig = R.readCards;
  R.readCards = (refs) => ({ ok: true, results: Object.fromEntries(refs.map((x) => [`${x.repo}#${x.number}`, { ok: false, reason: "pm-field-ambiguous" }])) });
  const before = G.calls();
  let r;
  try {
    const io = W.createPmField({ budgetMs: 3000 });
    io.prepare([ref(9721)]);
    r = io.write(ref(9721), "PM-x");
  } finally { R.readCards = orig; }
  assert.deepStrictEqual(r, { result: "failed", reason: "pm-field-ambiguous" });
  assert.strictEqual(G.calls() - before, 0);
});
caseEnd();

// The real createPmField.prepare -> readCards -> ensure-board-card.sh -> re-read path, every gh call on the fake gh.
// ensure-board-card.sh's first gh call is `gh auth status`; its presence in the log shows the script ran.
caseBegin("pm-field-prepare-through-fake-gh", "bin/lib/pm-field/write.js");
const since = (k) => G.queries().slice(k);
const ensured = (qs) => qs.filter((q) => q.startsWith("auth status")).length;
test("C1 a card on the first read: prepare runs no ensure-board-card.sh and the write edits that card", () => {
  G.setMap({ "o/r#9801": {} });
  G.setPmStore({});
  const k = G.calls();
  const io = W.createPmField({ budgetMs: 8000 });
  assert.deepStrictEqual(io.prepare([ref(9801)]), { ok: true });
  assert.deepStrictEqual(io.write(ref(9801), "PM-c1"), { result: "ok" });
  assert.strictEqual(G.pmStore()[item(9801)], "PM-c1");
  const qs = since(k);
  assert.strictEqual(ensured(qs), 0, qs.join("\n"));
  assert.ok(qs.some((q) => q.startsWith("api graphql")), qs.join("\n"));
  assert.ok(qs.some((q) => q.startsWith(`project item-edit --id ${item(9801)}`) && q.includes("--text PM-c1")), qs.join("\n"));
});
test("C2 no card on the first read, one on the re-read: prepare runs ensure-board-card.sh once, then the write lands", () => {
  G.setMap({ "o/r#9802": { noCard: 1 } });
  G.setPmStore({});
  const k = G.calls();
  const io = W.createPmField({ budgetMs: 15000 });
  assert.deepStrictEqual(io.prepare([ref(9802)]), { ok: true });
  const qs = since(k);
  assert.strictEqual(ensured(qs), 1, qs.join("\n"));
  assert.ok(qs.filter((q) => q.startsWith("api graphql") && q.includes("9802")).length >= 2, `no re-read after the card was added:\n${qs.join("\n")}`);
  assert.deepStrictEqual(io.write(ref(9802), "PM-c2"), { result: "ok" });
  assert.strictEqual(G.pmStore()[item(9802)], "PM-c2");
});
test("C3 no card even after ensure-board-card.sh: the write fails no-card and runs no item-edit", () => {
  G.setMap({ "o/r#9803": { noCard: true } });
  G.setPmStore({});
  const k = G.calls();
  const io = W.createPmField({ budgetMs: 15000 });
  assert.deepStrictEqual(io.prepare([ref(9803)]), { ok: true });
  assert.deepStrictEqual(io.write(ref(9803), "PM-c3"), { result: "failed", reason: "no-card" });
  const qs = since(k);
  assert.strictEqual(ensured(qs), 1, qs.join("\n"));
  assert.strictEqual(qs.filter((q) => q.startsWith("project item-edit")).length, 0, qs.join("\n"));
  assert.deepStrictEqual(G.pmStore(), {});
});
caseEnd();

caseBegin("writer-settles-an-unknown-write-by-re-reading", "hooks/pm-session/writer.js");
// Assumed: runPmWriter(input, {now, pmField:{write, read}}) — the PM field I/O is injectable; ancestry answers from the fake gh.
let n = 0;
const sid = () => P.uuid(0x29420100 + (++n));
function writeWith(pmField, prompt, s) {
  try {
    const run = P.load("hooks/pm-session/writer.js").runPmWriter;
    return run({ session_id: s, hook_event_name: "UserPromptSubmit", prompt, cwd: home }, { now: () => Date.now(), pmField }) || {};
  } catch (e) { return { threw: e.message }; }
}
// #3152: the writer writes through writeMany; withMany builds it on each fake's write.
const { withMany } = require("../lib/pm-s3-fixture");
const unknownWrite = (calls) => ({ write: (r, v) => { calls.push([r, v]); return { result: "unknown" }; } });
const valuesOf = (refs, v) => ({ ok: true, values: Object.fromEntries(refs.map((r) => [`${r.repo || "o/r"}#${r.number}`, v])) });
function addCase(label, read, expectAccepted, reasonRe) {
  test(label, () => {
    G.setMap({});
    const s = sid();
    const tag = `PM-u${n}`;
    P.seedPm(s, P.pm({ tag, issues: [9501 + n * 10] }));
    const before = P.readPm(s);
    const calls = [];
    const r = writeWith(withMany(Object.assign(unknownWrite(calls), { read: (refs) => read(refs, tag) })), P.wrapped("pm-add", `#${9502 + n * 10} reason`), s);
    assert.ok(calls.length >= 1, `the PM field was never written: ${JSON.stringify(r)}`);
    if (expectAccepted) {
      assert.ok(!r.block && !r.threw, JSON.stringify(r));
      assert.strictEqual(P.readPm(s).issues.length, 2, JSON.stringify(P.readPm(s)));
    } else {
      assert.ok(typeof r.block === "string" && reasonRe.test(r.block), JSON.stringify(r));
      assert.deepStrictEqual(P.readPm(s), before, "PM state changed after an unsettled write");
    }
  });
}
addCase("U1 unknown write, re-read shows the desired tag -> the PM state is written", (refs, tag) => valuesOf(refs, tag), true);
addCase("U2 unknown write, re-read shows the old value -> refused, PM state unchanged", (refs) => valuesOf(refs, null), false, /pm-field/i);
addCase("U3 unknown write, the re-read fails too -> refused with pm-field-write-unknown, PM state unchanged", () => ({ ok: false, reason: "timeout" }), false, /pm-field-write-unknown/);
test("U4 a failed write refuses without touching the PM state", () => {
  const s = sid();
  P.seedPm(s, P.pm({ tag: `PM-u${n}`, issues: [9601] }));
  const before = P.readPm(s);
  const calls = [];
  const r = writeWith(withMany({ write: (x, v) => { calls.push(v); return { result: "failed", reason: "HTTP 502" }; }, read: () => ({ ok: true, values: {} }) }), P.wrapped("pm-add", "#9602 reason"), s);
  assert.ok(calls.length >= 1, `the PM field was never written: ${JSON.stringify(r)}`);
  assert.ok(typeof r.block === "string" && r.block.length > 0, JSON.stringify(r));
  assert.deepStrictEqual(P.readPm(s), before);
});
caseEnd();

// #2942: a projectItems page with more cards than fetched cannot be read whole -> pm-field-truncated (fail-closed).
function blockEnd(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "{") depth++;
    if (s[i] === "}" && --depth === 0) return i;
  }
  return s.length;
}
// itemsTopLevel(sel) -> the projectItems(...){ } body with its nodes{...} block cut out (pageInfo must sit beside nodes).
function itemsTopLevel(sel) {
  const m = /projectItems\([^)]*\)\{/.exec(sel);
  if (!m) return "";
  const open = m.index + m[0].length - 1;
  const body = sel.slice(open + 1, blockEnd(sel, open));
  const n = body.indexOf("nodes{");
  return n < 0 ? body : body.slice(0, n) + body.slice(blockEnd(body, n + 5) + 1);
}
const truncated = (n, pms, o) => Object.assign(cardsOf(n, pms, o), { projectItems: Object.assign(cardsOf(n, pms, o).projectItems, { pageInfo: { hasNextPage: true } }) });
const TRUNC = { ok: false, reason: "pm-field-truncated" };
caseBegin("pm-field-truncated-read", "bin/lib/pm-field/read.js");
test("T1 ITEMS asks projectItems for pageInfo{hasNextPage}", () => {
  assert.match(itemsTopLevel(R.ITEMS), /pageInfo\s*\{\s*hasNextPage\s*\}/, R.ITEMS);
});
test("T2 pmReadOf: hasNextPage true is pm-field-truncated even with one value; false reads the value", () => {
  assert.deepStrictEqual(R.pmReadOf(truncated(9901, ["PM-a"])), TRUNC);
  assert.deepStrictEqual(R.pmReadOf(truncated(9902, ["PM-a", "PM-b"])), TRUNC);
  const notMore = cardsOf(9903, ["PM-a"]);
  assert.deepStrictEqual(R.pmReadOf(Object.assign(notMore, { projectItems: Object.assign(notMore.projectItems, { pageInfo: { hasNextPage: false } }) })), { ok: true, pm: "PM-a" });
});
test("T3 cardOf (via readCards): a truncated card page is pm-field-truncated, a whole one a card", () => {
  const M = freshRead({ "o/r#9911": truncated(9911, [null]), "o/r#9912": cardsOf(9912, [null]) });
  assert.deepStrictEqual(M.readCards([ref(9911)]).results["o/r#9911"], TRUNC);
  assert.strictEqual(M.readCards([ref(9912)]).results["o/r#9912"].ok, true);
});
test("T4 fake gh: readPmFields, readCards and readPmChains fail closed on a truncated page", () => {
  G.setPmStore({});
  G.setMap({ "o/r#9921": { pm: "PM-a", itemsMore: true }, "o/r#9922": { pm: "PM-a", itemsMore: false }, "o/r#9923": { parent: { number: 9924 } }, "o/r#9924": { pm: "PM-p", itemsMore: true } });
  assert.deepStrictEqual(R.readPmFields([ref(9921)], { timeoutMs: 5000 }), TRUNC);
  assert.deepStrictEqual(R.readPmFields([ref(9922)], { timeoutMs: 5000 }), { ok: true, values: { "o/r#9922": "PM-a" } });
  const cards = R.readCards([ref(9921), ref(9922)], { timeoutMs: 5000 });
  assert.deepStrictEqual(cards.results["o/r#9921"], TRUNC, JSON.stringify(cards));
  assert.strictEqual(cards.results["o/r#9922"].ok, true, JSON.stringify(cards));
  const chains = R.readPmChains([ref(9923)], { timeoutMs: 5000 });
  assert.deepStrictEqual(chains.results["o/r#9923"], TRUNC, JSON.stringify(chains));
});
test("T5 fake gh: an error inside the issue node makes readPmFields gh_exec_failed, never a null value", () => {
  G.setPmStore({});
  for (const type of ["FORBIDDEN", "NOT_FOUND"]) {
    G.setMap({ "o/r#9931": { pm: "PM-a", innerError: type }, "o/r#9932": { pm: "PM-b" } });
    const r = R.readPmFields([ref(9931), ref(9932)], { timeoutMs: 5000 });
    assert.deepStrictEqual(r, { ok: false, reason: "gh_exec_failed" }, `${type}: ${JSON.stringify(r)}`);
  }
});
caseEnd();
caseBegin("pm-field-truncated-write", "bin/lib/pm-field/write.js");
test("T6 a truncated card page makes the write fail with pm-field-truncated (not no-card) and runs no edit", () => {
  const orig = R.readCards;
  R.readCards = (refs) => ({ ok: true, results: Object.fromEntries(refs.map((x) => [`${x.repo}#${x.number}`, TRUNC])) });
  const before = G.calls();
  let r;
  try {
    const io = W.createPmField({ budgetMs: 3000 });
    io.prepare([ref(9961)]);
    r = io.write(ref(9961), "PM-x");
  } finally { R.readCards = orig; }
  assert.deepStrictEqual(r, { result: "failed", reason: "pm-field-truncated" });
  assert.strictEqual(G.calls() - before, 0);
});
caseEnd();
caseBegin("pm-field-reread-fail-closed", "bin/lib/pm-field/write.js");
test("T7 no-card on the first read, a fail-closed re-read after ensure-board-card.sh: the write keeps that reason (table-driven)", () => {
  const rows = [{ n: 9971, re: TRUNC }, { n: 9972, re: { ok: false, reason: "pm-field-ambiguous" } }];
  for (const { n, re } of rows) {
    G.setMap({ [`o/r#${n}`]: { noCard: true } });
    G.setPmStore({});
    const orig = R.readCards;
    let reads = 0;
    R.readCards = (refs) => { reads++; const v = reads === 1 ? { ok: false, reason: "no-card" } : re; return { ok: true, results: Object.fromEntries(refs.map((x) => [`${x.repo}#${x.number}`, v])) }; };
    const k = G.calls();
    let r;
    try {
      const io = W.createPmField({ budgetMs: 15000 });
      io.prepare([ref(n)]);
      r = io.write(ref(n), "PM-x");
    } finally { R.readCards = orig; }
    const qs = since(k);
    assert.strictEqual(reads, 2, `${re.reason}: prepare did not re-read`);
    assert.strictEqual(ensured(qs), 1, `${re.reason}: ensure-board-card.sh did not run:\n${qs.join("\n")}`);
    assert.deepStrictEqual(r, { result: "failed", reason: re.reason }, re.reason);
    assert.strictEqual(qs.filter((q) => q.startsWith("project item-edit")).length, 0, qs.join("\n"));
  }
});
caseEnd();

// #2942: a card counts only on a Project with the `pm` field; a card elsewhere is no card (never a blind write).
const mixed = (n, fields) => ({ number: n, repository: { nameWithOwner: "o/r" }, parent: null,
  projectItems: { nodes: fields.map((f, i) => ({ id: `I${n}-${i}`, pm: null, project: { id: `P${i}`, field: f ? { id: `F${i}` } : null } })) } });
caseBegin("pm-field-card-needs-pm-field", "bin/lib/pm-field/read.js");
test("C16 cardOf: a card counts only on a Project with the pm field (table-driven)", () => {
  const NO_CARD = { ok: false, reason: "no-card" };
  const cases = [
    { name: "one card, no pm-field board -> no-card", n: 9941, node: mixed(9941, [false]), want: NO_CARD },
    { name: "two cards, no pm-field board -> no-card", n: 9942, node: mixed(9942, [false, false]), want: NO_CARD },
    { name: "one pm-field board among others -> that card", n: 9943, node: mixed(9943, [false, true, false]), want: { ok: true, itemId: "I9943-1", projectId: "P1", fieldId: "F1" } },
    { name: "two pm-field boards -> pm-field-ambiguous", n: 9944, node: mixed(9944, [true, false, true]), want: { ok: false, reason: "pm-field-ambiguous" } },
    { name: "no cards -> no-card", n: 9945, node: mixed(9945, []), want: NO_CARD },
    { name: "truncated page -> pm-field-truncated", n: 9946, node: truncated(9946, [null]), want: TRUNC },
  ];
  const M = freshRead(Object.fromEntries(cases.map((c) => [`o/r#${c.n}`, c.node])));
  const got = M.readCards(cases.map((c) => ref(c.n))).results;
  for (const { name, n, want } of cases) assert.deepStrictEqual(got[`o/r#${n}`], want, name);
});
caseEnd();
caseBegin("pm-field-prepare-card-without-pm-field", "bin/lib/pm-field/write.js");
test("C16 prepare: the only card is on a Project without the pm field -> ensure-board-card.sh runs; the write fails with no item-edit", () => {
  G.setMap({ "o/r#9951": { noPmField: true } });
  G.setPmStore({});
  const k = G.calls();
  const io = W.createPmField({ budgetMs: 15000 });
  assert.deepStrictEqual(io.prepare([ref(9951)]), { ok: true });
  const qs = since(k);
  assert.strictEqual(ensured(qs), 1, `ensure-board-card.sh did not run for a card off the pm-field board:\n${qs.join("\n")}`);
  assert.ok(qs.filter((q) => q.startsWith("api graphql") && q.includes("9951")).length >= 2, `no re-read:\n${qs.join("\n")}`);
  const r = io.write(ref(9951), "PM-c16");
  assert.strictEqual(r.result, "failed", JSON.stringify(r));
  assert.strictEqual(since(k).filter((q) => q.startsWith("project item-edit")).length, 0, since(k).join("\n"));
  assert.deepStrictEqual(G.pmStore(), {});
});
caseEnd();

// #3152: a board lookup that answers neither resolved nor fetch-failed fails its issues board-<status>, no card spawn.
caseBegin("pm-field-prepare-board-unresolved", "bin/lib/pm-field/write.js");
test("B2 resolveBoard answers no-link / ambiguous: the issue fails board-<status>, no ensure-board-card.sh, no edit", () => {
  for (const [i, status] of ["no-link", "ambiguous"].entries()) {
    const n = 9981 + i;
    const orig = R.readCards;
    let reads = 0;
    R.readCards = (refs) => { reads++; return { ok: true, results: Object.fromEntries(refs.map((x) => [`${x.repo}#${x.number}`, { ok: false, reason: "no-card" }])) }; };
    const spawns = [];
    const boards = [];
    let r;
    try {
      const io = W.createPmField({ budgetMs: 15000, spawnSync: (...a) => { spawns.push(a); return { status: 0, signal: null, stdout: "", stderr: "" }; }, resolveBoard: (repo) => { boards.push(repo); return { status }; } });
      assert.deepStrictEqual(io.prepare([ref(n)]), { ok: true });
      r = io.write(ref(n), "PM-b2");
    } finally { R.readCards = orig; }
    assert.deepStrictEqual(boards, ["o/r"], status);
    assert.strictEqual(reads, 2, `${status}: prepare did not re-read`);
    assert.deepStrictEqual(spawns, [], `${status}: a card spawn or an edit ran`);
    assert.deepStrictEqual(r, { result: "failed", reason: `board-${status}` });
  }
});
caseEnd();

"use strict";
// Tests: bin/lib/tracker-fields/expected.js, bin/lib/tracker-fields/judge.js, bin/lib/tracker-fields/backfill.js, skills/migrate-tracker/scripts/repair.js, skills/migrate-tracker/scripts/needs.js
// Tags: TL2, scope:issue-specific, pm-session, pm-field, migrate, issue-3135, feature-3142, projects-v2
// #3135 detection and repair of a board without the `pm` field. Assumed contracts (named by this test):
//   expected.js EXPECTED_FIELDS [{name, dataType, options?}]; judge.js judge({fields, holders, values}) ->
//   {needed, missing, diagnostics:[{kind, message}]}; backfill.js backfillPm({repo, read, write, entries?}) ->
//   {ok, written, skipped, failed}; repair.js repair({judge, ensure, backfill}) -> {ok, reason?}.
// TL3 gap (what this test does NOT catch):
// - the real field discovery query and ensure-project-ready.sh against GitHub; the forge I/O is injected here.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, F } = X;
after(() => { restore(); });

const TABLE = () => P.load("bin/lib/tracker-fields/expected.js");
const JUDGE = () => P.load("bin/lib/tracker-fields/judge.js");
const BACKFILL = () => P.load("bin/lib/tracker-fields/backfill.js");
const REPAIR = () => P.load("skills/migrate-tracker/scripts/repair.js");
const at = (num, repo) => `${repo || "o/r"}#${num}`;
const own = (nums, repo) => nums.map((num) => ({ number: num, repo: repo || "o/r" }));
const brief = (r) => JSON.stringify(r).slice(0, 600);
let n = 0;
const seed = (tag, issues, extra) => P.seedPm(P.uuid(0x31354000 + (++n)), P.pm(Object.assign({ tag, issues }, extra || {})));

const STATUS = { name: "Status", dataType: "SINGLE_SELECT", options: [{ name: "Todo" }, { name: "In Progress" }, { name: "Done" }] };
const FULL = [{ name: "Content Date", dataType: "DATE" }, STATUS, { name: "session-id", dataType: "TEXT" }, { name: "pm", dataType: "TEXT" }];
const fieldsOf = (nodes) => ({ ok: true, nodes });
const without = (name) => FULL.filter((f) => f.name !== name);
const kinds = (r) => (r.diagnostics || []).map((d) => d.kind);
function judge(o) {
  const f = JUDGE().judge;
  assert.strictEqual(typeof f, "function", "judge.js exports no judge");
  return f(Object.assign({ fields: fieldsOf(FULL), holders: {}, values: { ok: true, values: {} } }, o));
}

caseBegin("expected-field-table", "bin/lib/tracker-fields/expected.js");
test("F1 the table names every field the tracker board needs, with its dataType and options", () => {
  const t = TABLE().EXPECTED_FIELDS;
  assert.ok(Array.isArray(t), "EXPECTED_FIELDS is not an array");
  const shape = t.map((f) => [f.name, f.dataType, (f.options || []).map((o) => (typeof o === "string" ? o : o.name))]);
  assert.deepStrictEqual(shape.sort(), [["Content Date", "DATE", []], ["Status", "SINGLE_SELECT", ["Todo", "In Progress", "Done"]],
    ["pm", "TEXT", []], ["session-id", "TEXT", []]].sort());
});
// The board preparation reading the table is checked by behaviour in feature-3135-pm-field-migrate-path.js (F3/F4).
test("F2 the pm reader's field name is in the table", () => {
  const t = TABLE().EXPECTED_FIELDS;
  assert.ok(t.some((f) => f.name === P.load("bin/lib/pm-field/read.js").PM_FIELD_NAME), "the pm reader's field is not in the table");
});
caseEnd();

caseBegin("forge-judge", "bin/lib/tracker-fields/judge.js");
test("J1 a complete, backfilled board is neither needed nor diagnosed", () => {
  const r = judge({ holders: { [at(9201)]: ["PM-a"] }, values: { ok: true, values: { [at(9201)]: "PM-a" } } });
  assert.deepStrictEqual([r.needed, r.missing, r.diagnostics], [false, [], []], brief(r));
});
test("J2 only a missing field is NEEDED, and every missing one is named", () => {
  const r = judge({ fields: fieldsOf(without("pm")) });
  assert.deepStrictEqual([r.needed, r.missing], [true, ["pm"]], brief(r));
  const two = judge({ fields: fieldsOf(FULL.filter((f) => !["pm", "session-id"].includes(f.name))) });
  assert.deepStrictEqual([two.needed, two.missing.slice().sort()], [true, ["pm", "session-id"]], brief(two));
});
test("J2b Content Date missing alone is NEEDED and named", () => {
  const r = judge({ fields: fieldsOf(without("Content Date")) });
  assert.deepStrictEqual([r.needed, r.missing], [true, ["Content Date"]], brief(r));
});
test("J2c Status missing alone is NEEDED and named", () => {
  const r = judge({ fields: fieldsOf(without("Status")) });
  assert.deepStrictEqual([r.needed, r.missing], [true, ["Status"]], brief(r));
});
test("J3 a dataType mismatch and a missing option are diagnostics, not NEEDED", () => {
  const typed = judge({ fields: fieldsOf(without("pm").concat([{ name: "pm", dataType: "SINGLE_SELECT", options: [] }])) });
  assert.strictEqual(typed.needed, false, brief(typed));
  assert.ok(kinds(typed).includes("type-mismatch"), brief(typed));
  const opt = judge({ fields: fieldsOf(without("Status").concat([Object.assign({}, STATUS, { options: STATUS.options.slice(0, 2) })])) });
  assert.strictEqual(opt.needed, false, brief(opt));
  assert.ok(kinds(opt).includes("option-missing"), brief(opt));
});
test("J4 a held issue whose field is empty is an unbackfilled diagnostic, never NEEDED", () => {
  const r = judge({ holders: { [at(9201)]: ["PM-a"], [at(9202)]: ["PM-a"] }, values: { ok: true, values: { [at(9201)]: null, [at(9202)]: "PM-a" } } });
  assert.strictEqual(r.needed, false, brief(r));
  const d = r.diagnostics.find((x) => x.kind === "unbackfilled");
  assert.ok(d, brief(r));
  assert.strictEqual(d.count, 1, brief(d));
});
test("J5a the field names another PM than the local holder: backfill-conflict, never NEEDED", () => {
  const r = judge({ holders: { [at(9203)]: ["PM-a"] }, values: { ok: true, values: { [at(9203)]: "PM-other" } } });
  assert.strictEqual(r.needed, false, brief(r));
  assert.ok(kinds(r).includes("backfill-conflict"), brief(r));
});
test("J5b two local holders of an empty field: backfill-conflict, never NEEDED", () => {
  const r = judge({ holders: { [at(9204)]: ["PM-a", "PM-b"] }, values: { ok: true, values: { [at(9204)]: null } } });
  assert.strictEqual(r.needed, false, brief(r));
  assert.ok(kinds(r).includes("backfill-conflict"), brief(r));
});
test("J6 a forge failure is the undecidable diagnostic, never NEEDED", () => {
  const r = judge({ fields: { ok: false, reason: "gh_exec_failed" } });
  assert.strictEqual(r.needed, false, brief(r));
  assert.ok(kinds(r).includes("undecidable"), brief(r));
  const v = judge({ holders: { [at(9201)]: ["PM-a"] }, values: { ok: false, reason: "timeout" } });
  assert.strictEqual(v.needed, false, brief(v));
  assert.ok(kinds(v).includes("undecidable"), brief(v));
});
test("J7 (T2) the unbackfilled diagnostic tells in one line how to run /migrate-tracker", () => {
  const r = judge({ holders: { [at(9201)]: ["PM-a"] }, values: { ok: true, values: { [at(9201)]: null } } });
  const d = r.diagnostics.find((x) => x.kind === "unbackfilled");
  assert.ok(d && typeof d.message === "string", brief(r));
  assert.strictEqual(d.message.split(/\r?\n/).filter((l) => /\/migrate-tracker\b/.test(l)).length, 1, d.message);
});
test("J8 needs.js keeps its no-forge contract (no gh call)", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pm-judge-needs-"));
  try {
    const before = X.G.calls();
    try { require(path.join(P.ROOT, "skills", "migrate-tracker", "scripts", "needs.js")).needs(root); } catch (_) { /* a judgment error is not the point */ }
    assert.strictEqual(X.G.calls(), before, "needs.js called gh");
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
caseEnd();

caseBegin("pm-backfill", "bin/lib/tracker-fields/backfill.js");
function backfill(field, extra) {
  const f = BACKFILL().backfillPm;
  assert.strictEqual(typeof f, "function", "backfill.js exports no backfillPm");
  return f(Object.assign({ repo: "o/r", read: field.read, write: field.write }, extra || {}));
}
function seedBoard() {
  seed("PM-b1", own([9211, 9212, 9213, 9214]));
  seed("PM-b2", own([9213]));
  seed("PM-b3", own([9216]), { archived_at: "2026-11-09T00:00:00.000Z" });
  seed("PM-b4", own([9215], "x/y"));
  return X.field({ [at(9212)]: "PM-b1", [at(9214)]: "PM-other" });
}
test("B1 writes only an empty field with exactly one active holder in the target repo", () => F.alone(() => {
  const fld = seedBoard();
  const r = backfill(fld);
  assert.strictEqual(r.ok, true, brief(r));
  assert.deepStrictEqual(fld.writes, [{ ref: at(9211), value: "PM-b1" }], brief(fld.writes));
  assert.strictEqual(fld.values[at(9214)], "PM-other", "a field value was overwritten");
  const skipped = (r.skipped || []).map((s) => String(s.issue).toLowerCase());
  assert.ok(skipped.includes(at(9213)) && skipped.includes(at(9214)), brief(r));
}));
test("B2 a second run writes nothing", () => F.alone(() => {
  const fld = seedBoard();
  backfill(fld);
  const before = fld.writes.length;
  const r = backfill(fld);
  assert.strictEqual(r.ok, true, brief(r));
  assert.strictEqual(fld.writes.length, before, brief(fld.writes));
}));
test("B3 a failed write or a failed read fails the run", () => F.alone(() => {
  const fld = seedBoard();
  const w = backfill(fld, { write: (ref, v) => { fld.writes.push({ ref: at(ref.number), value: v }); return { result: "failed", reason: "HTTP 502" }; } });
  assert.strictEqual(w.ok, false, brief(w));
  assert.ok((w.failed || []).some((x) => String(x.issue).toLowerCase() === at(9211)), brief(w));
  const before = fld.writes.length;
  const rd = backfill(fld, { read: () => ({ ok: false, reason: "timeout" }) });
  assert.strictEqual(rd.ok, false, brief(rd));
  assert.strictEqual(fld.writes.length, before, "wrote after a failed read");
}));
test("B4 (T1) the empty check and the write run inside the PM lock that /pm-add and /pm-init take", () => F.alone(() => {
  const fld = seedBoard();
  const seen = [];
  const r = backfill(fld, {
    read: (refs) => { seen.push(["read", fs.existsSync(X.lockPath())]); return fld.read(refs); },
    write: (ref, v) => { seen.push(["write", fs.existsSync(X.lockPath())]); return fld.write(ref, v); },
  });
  assert.strictEqual(r.ok, true, brief(r));
  assert.ok(seen.some((s) => s[0] === "write"), brief(seen));
  assert.ok(seen.every((s) => s[1] === true), `a read or write ran outside the PM lock: ${brief(seen)}`);
}));
test("B5 (T1) while another PM command holds the lock nothing is written and the run fails", () => F.alone(() => {
  const fld = seedBoard();
  const h = X.holdLock();
  try {
    const r = backfill(fld);
    assert.strictEqual(r.ok, false, brief(r));
    assert.deepStrictEqual(fld.writes, []);
  } finally { h.release(); }
}));
caseEnd();

caseBegin("repair-path", "skills/migrate-tracker/scripts/repair.js");
const NEEDED = { needed: true, missing: ["pm"], diagnostics: [] };
const CLEAN = { needed: false, missing: [], diagnostics: [] };
const UNBACKFILLED = { needed: false, missing: [], diagnostics: [{ kind: "unbackfilled", count: 1, message: "x" }] };
const UNDECIDABLE = { needed: false, missing: [], diagnostics: [{ kind: "undecidable", message: "x" }] };
// run(judges, ensure, backfill) -> {r, calls}: judge answers judges[i] on its i-th call.
function run(judges, ensureOk, backfillOk) {
  const f = REPAIR().repair;
  assert.strictEqual(typeof f, "function", "repair.js exports no repair");
  const calls = [];
  let j = 0;
  const r = f({
    judge: () => { calls.push("judge"); return judges[Math.min(j++, judges.length - 1)]; },
    ensure: () => { calls.push("ensure"); return ensureOk ? { ok: true } : { ok: false, reason: "createProjectV2Field failed" }; },
    backfill: () => { calls.push("backfill"); return backfillOk ? { ok: true, written: [], skipped: [], failed: [] } : { ok: false, failed: [{ issue: at(9211), reason: "x" }] }; },
  });
  return { r, calls };
}
test("R1 (a) NEEDED: prepare, judge again, then backfill", () => {
  const { r, calls } = run([NEEDED, CLEAN], true, true);
  assert.strictEqual(r.ok, true, brief(r));
  assert.deepStrictEqual(calls, ["judge", "ensure", "judge", "backfill"]);
});
test("R2 (a) a failed preparation fails the step before any backfill", () => {
  const { r, calls } = run([NEEDED, CLEAN], false, true);
  assert.strictEqual(r.ok, false, brief(r));
  assert.ok(!calls.includes("backfill"), brief(calls));
});
test("R3 (a) fail-closed: still missing or undecidable after preparation fails the step, no backfill", () => {
  for (const again of [NEEDED, UNDECIDABLE]) {
    const { r, calls } = run([NEEDED, again], true, true);
    assert.strictEqual(r.ok, false, brief(again));
    assert.ok(!calls.includes("backfill"), brief(calls));
  }
});
test("R4 (b) unbackfilled only: backfill without preparing the board", () => {
  const { r, calls } = run([UNBACKFILLED], true, true);
  assert.strictEqual(r.ok, true, brief(r));
  assert.ok(calls.includes("backfill") && !calls.includes("ensure"), brief(calls));
});
test("R5 a failed backfill write fails the step", () => {
  for (const judges of [[NEEDED, CLEAN], [UNBACKFILLED]]) {
    const { r } = run(judges, true, false);
    assert.strictEqual(r.ok, false, brief(judges));
  }
});
test("R6 nothing to repair, or only an undecidable judge, touches nothing", () => {
  for (const j of [CLEAN, UNDECIDABLE, { needed: false, missing: [], diagnostics: [{ kind: "type-mismatch", message: "x" }] }]) {
    const { calls } = run([j], true, true);
    assert.deepStrictEqual(calls, ["judge"], brief(j));
  }
});
caseEnd();

// ---- #3142 Step 6: the judge reads the board the resolver names (resolveBoard), never one matched by title ----
//   boardFields(repo, timeoutMs, {resolveBoard}) -> no-link {ok:false, noBoard:true}; ambiguous / fetch-failed
//   {ok:false, reason}; resolved -> the field pages of board.projectId. judge({fields:{noBoard}}) -> no-board.
// TL3 gap: the real resolver spawn and the live field query; resolveBoard is injected, gh is the #3142 JSON mock.
const TMP3142 = fs.mkdtempSync(path.join(os.tmpdir(), "f3142-judge-"));
after(() => { fs.rmSync(TMP3142, { recursive: true, force: true }); });
const LOG3142 = path.join(TMP3142, "gh.log");
const MOCKBIN = path.join(TMP3142, "mockbin");
fs.mkdirSync(path.join(TMP3142, "home"));
fs.mkdirSync(MOCKBIN);
const mockSh = path.join(__dirname, "feature-3142-board-resolve", "_gh-mock.sh").replace(/\\/g, "/");
fs.writeFileSync(path.join(MOCKBIN, "gh"), `#!/usr/bin/env bash\nexec bash "${mockSh}" "$@"\n`, { mode: 0o755 });
// with3142Mock(fn) — runs fn with HOME and the #3142 gh mock pinned, then puts back every key it touched,
// so the pm-s3 fixture's own gh mock and HOME stay as the cases above left them.
function with3142Mock(fn, extra) {
  const keys = ["HOME", "USERPROFILE", "PATH", "GH_MOCK_LOG", "GH_MOCK_REPO", "GH_MOCK_LINKED_FILE"];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  const home = path.join(TMP3142, "home");
  delete process.env.GH_MOCK_LINKED_FILE;
  Object.assign(process.env, { HOME: home, USERPROFILE: home, PATH: MOCKBIN + path.delimiter + process.env.PATH,
    GH_MOCK_LOG: LOG3142, GH_MOCK_REPO: "o/r" }, extra || {});
  fs.writeFileSync(LOG3142, "");
  try { return fn(); } finally {
    for (const k of keys) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  }
}
// boardFieldsOf(board) -> boardFields' answer with a synchronous resolveBoard stub (as resolve.js's is) and its calls.
// judgeRepo, and migrate-needs.js after it, call boardFields synchronously: a thenable answer is a failure.
const notThenable = (x) => assert.ok(!x || typeof x.then !== "function", "answer is a Promise; callers are sync");
function boardFieldsOf(board) {
  const calls = [];
  const resolveBoard = (repo, opts) => { calls.push({ repo, opts }); return board; };
  const f = with3142Mock(() => JUDGE().boardFields("o/r", 5000, { resolveBoard }));
  notThenable(f);
  return { f, calls, log: fs.readFileSync(LOG3142, "utf8") };
}
const judgeFields = (f) => JUDGE().judge({ fields: f, holders: {}, values: { ok: true, values: {} } });
const RESOLVED = { status: "resolved", owner: "o", number: 3, projectId: "PVT_x", fieldIds: {}, candidates: [] };

caseBegin("no-board-diagnostic", "bin/lib/tracker-fields/judge.js");
test("JB1 judge on a no-board answer is not NEEDED and diagnoses no-board", () => {
  const r = judgeFields({ ok: false, noBoard: true, reason: "no-link" });
  assert.strictEqual(r.needed, false, brief(r));
  assert.deepStrictEqual(kinds(r), ["no-board"], brief(r));
  assert.match(r.diagnostics[0].message, /\/migrate-tracker/, brief(r));
});
test("JB2 a plain field read failure stays undecidable", () => {
  const r = judgeFields({ ok: false, reason: "boom" });
  assert.deepStrictEqual(kinds(r), ["undecidable"], brief(r));
});
caseEnd();

caseBegin("board-from-resolver", "bin/lib/tracker-fields/judge.js");
test("JB3 no-link is noBoard and reaches judge as no-board", () => {
  const { f, calls } = boardFieldsOf({ status: "no-link", candidates: [] });
  assert.strictEqual(calls.length, 1, `resolveBoard not consulted: ${brief(f)}`);
  assert.strictEqual(calls[0].repo, "o/r");
  assert.strictEqual(calls[0].opts && calls[0].opts.noCacheRead, true, "the judge path must not read the cache");
  assert.deepStrictEqual([f.ok, f.noBoard], [false, true], brief(f));
  assert.deepStrictEqual(kinds(judgeFields(f)), ["no-board"]);
});
test("JB4 ambiguous is undecidable and names the candidates", () => {
  const { f } = boardFieldsOf({ status: "ambiguous", candidates: ["o#3", "o#4"] });
  assert.strictEqual(f.ok, false, brief(f));
  assert.ok(!f.noBoard, brief(f));
  assert.match(String(f.reason), /ambiguous.*o#3.*o#4/, brief(f));
  assert.deepStrictEqual(kinds(judgeFields(f)), ["undecidable"]);
});
test("JB5 fetch-failed is undecidable", () => {
  const { f, calls } = boardFieldsOf({ status: "fetch-failed", reason: "timeout", candidates: [] });
  assert.strictEqual(calls.length, 1, `resolveBoard not consulted: ${brief(f)}`);
  assert.strictEqual(f.ok, false, brief(f));
  assert.ok(!f.noBoard, brief(f));
  assert.deepStrictEqual(kinds(judgeFields(f)), ["undecidable"]);
});
test("JB6 resolved reads the fields of the resolved board without a title lookup", () => {
  const { f, log } = boardFieldsOf(RESOLVED);
  assert.strictEqual(f.ok, true, brief(f));
  assert.deepStrictEqual(f.nodes.map((x) => x.name).sort(), ["Content Date", "Status", "session-id"], brief(f));
  assert.ok(/projectId=PVT_x/.test(log), `field query not aimed at the resolved board: ${log.slice(0, 400)}`);
  assert.ok(!/^project list/m.test(log), `title lookup still made: ${log.slice(0, 400)}`);
});
caseEnd();

caseBegin("judge-repo-stays-sync", "bin/lib/tracker-fields/judge.js");
// migrate-needs.js calls judgeRepo(repo) synchronously with no injection; the default resolver must keep it sync.
// The mock repo links no board, so the real resolver answers no-link and the judge diagnoses no-board.
test("JB7 judgeRepo with the default resolver returns a plain answer, not a Promise", () => {
  const r = with3142Mock(() => JUDGE().judgeRepo("o/r", { timeoutMs: 5000, entries: [] }));
  notThenable(r);
  assert.strictEqual(typeof r.needed, "boolean", brief(r));
  assert.ok(Array.isArray(r.diagnostics), brief(r));
  assert.deepStrictEqual(kinds(r), ["no-board"], brief(r));
});
// The repo links one open board PVT_lnk: the real resolver (node -> bash) must name it, and the field query must aim at it.
test("JB8 boardFields with the default resolver queries the fields of the linked board's id", () => {
  const linked = path.join(TMP3142, "linked.json");
  fs.writeFileSync(linked, JSON.stringify({ nodes: [{ id: "PVT_lnk", number: 5, closed: false, owner: { login: "o" } }],
    pageInfo: { hasNextPage: false, endCursor: null } }));
  const f = with3142Mock(() => JUDGE().boardFields("o/r", 5000), { GH_MOCK_LINKED_FILE: linked });
  notThenable(f);
  const log = fs.readFileSync(LOG3142, "utf8");
  assert.ok(/projectsV2/.test(log), `the resolver did not ask for the linked boards: ${log.slice(0, 400)}`);
  assert.strictEqual(f.ok, true, brief(f));
  assert.ok(/fields\(/.test(log) && /projectId=PVT_lnk/.test(log), `field query not aimed at PVT_lnk: ${log.slice(0, 600)}`);
  assert.ok(!/^project list/m.test(log), `title lookup still made: ${log.slice(0, 400)}`);
});
caseEnd();

"use strict";
// tests/hooks/feat-pm-writer-fail-safe.js
// Tests: hooks/pm-session/writer.js, hooks/user-prompt-submit-issue-title/title.js, bin/workflow/workflow-init-driver
// Tags: TL1, TL2, scope:common, issue-2942, pm-session, user-prompt-submit, fail-safe, driver, pm-field, one-owner
// #2942 S1 fail-safe: the PM writer refuses (block with a reason) when a PM command (hit or undecidable)
// meets an unreadable state, or a PM session meets an undecidable prompt; any other prompt passes.
// title.respond turns a throwing writer into a refusal only for PM-command prompts. The driver maps an
// isPmSession exception to ACTION=blocked REASON=pm-session-undecidable. "Unreadable" = invalid JSON.
// TL3 gap: a live UserPromptSubmit / Skill-tool round trip is not driven; writer, respond and the driver
// run directly with a fixture state store and a gh that always fails.

const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-failsafe-"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const writer = () => P.load("hooks/pm-session/writer.js");
const WRITER_PATH = path.join(P.ROOT, "hooks", "pm-session", "writer.js");
const title = () => require(path.join(P.ROOT, "hooks", "user-prompt-submit-issue-title", "title.js"));
let n = 0x29420100;
const freshSid = () => P.uuid(n++);
const corrupt = (sid) => fs.writeFileSync(P.statePath(sid), "{ not json");
const DEPS = { now: () => Date.parse("2026-11-21T00:00:00.000Z"), fetchTitle: () => null, spawnSync: () => ({ status: 1, stdout: "", stderr: "offline" }) };
const call = (sid, prompt) => writer().runPmWriter({ session_id: sid, prompt, cwd: tmp }, DEPS) || {};
const isRefusal = (r) => typeof r.block === "string" && /\[pm-session\]/.test(r.block) && r.block.length > "[pm-session]".length + 5;
const UNDECIDABLE = "<ide_opened_file>opened a.md\n/pm-init PM-x #1";

caseBegin("writer-refuses-unreadable-state", "hooks/pm-session/writer.js");
for (const [label, prompt] of [
  ["typed /wf-init", "/wf-init #12"],
  ["typed /workflow-init (wrapped)", P.wrapped("workflow-init", "#12")],
  ["typed /pm-add", "/pm-add #5 reason"],
  ["typed /pm-remove", "/pm-remove #5"],
  ["undecidable prompt carrying /pm-init", UNDECIDABLE],
]) {
  test(`${label} + unreadable state -> refused with a reason`, () => {
    const sid = freshSid();
    corrupt(sid);
    let r;
    assert.doesNotThrow(() => { r = call(sid, prompt); }, "the writer must refuse, not throw");
    assert.ok(isRefusal(r), JSON.stringify(r));
  });
}
caseEnd();

caseBegin("writer-pm-session-undecidable", "hooks/pm-session/writer.js");
test("PM session + undecidable prompt -> refused", () => {
  const sid = freshSid();
  P.seedPm(sid, P.pm({ tag: "PM-fs1", issues: [11] }));
  assert.ok(isRefusal(call(sid, UNDECIDABLE)));
  assert.deepStrictEqual(P.readPm(sid).issues, [{ number: 11 }], "a refusal must not change pm");
});
test("PM session + undecidable non-command prompt (unknown tag) -> refused", () => {
  const sid = freshSid();
  P.seedPm(sid, P.pm({ tag: "PM-fs2", issues: [12] }));
  assert.ok(isRefusal(call(sid, "<foo_bar>x</foo_bar>\nplease continue")));
});
caseEnd();

caseBegin("writer-passes-non-pm-prompts", "hooks/pm-session/writer.js");
for (const [label, seed, prompt] of [
  ["plain prose + unreadable state", corrupt, "please look at #5"],
  ["non-PM command + unreadable state", corrupt, "/commit-push #12"],
  ["non-PM session + undecidable prompt (state readable)", (sid) => P.seedState(sid), UNDECIDABLE],
  ["PM session + plain prose", (sid) => P.seedPm(sid, P.pm({ tag: "PM-fs3", issues: [13] })), "go on with the plan"],
  ["no state file + typed /wf-init (missing is not unreadable)", () => {}, "/wf-init #12"],
]) {
  test(`${label} -> passes (no block)`, () => {
    const sid = freshSid();
    seed(sid);
    const r = call(sid, prompt);
    assert.ok(!r.block, JSON.stringify(r));
  });
}
caseEnd();

// respond() with a writer that throws: the stand-in replaces runPmWriter on the cached module object,
// which respond reads at call time.
function withThrowingWriter(fn) {
  const mod = require(WRITER_PATH);
  const orig = mod.runPmWriter;
  mod.runPmWriter = () => { throw new Error("writer exploded"); };
  try { return fn(); } finally { mod.runPmWriter = orig; }
}
caseBegin("respond-throwing-writer", "hooks/user-prompt-submit-issue-title/title.js");
for (const [label, prompt] of [["typed /pm-init", "/pm-init PM-a #1"], ["typed /wf-init", "/wf-init #3"], ["undecidable PM command", UNDECIDABLE]]) {
  test(`${label} + throwing writer -> refusal`, () => {
    const r = withThrowingWriter(() => title().respond({ session_id: freshSid(), prompt, cwd: tmp }, DEPS));
    assert.ok(typeof r.block === "string" && r.block.length > 0, JSON.stringify(r));
    assert.strictEqual(r.title, null);
  });
}
for (const [label, prompt] of [["plain prose", "please look at #5"], ["non-PM command", "/commit-push #12"]]) {
  test(`${label} + throwing writer -> passes (no block)`, () => {
    const r = withThrowingWriter(() => title().respond({ session_id: freshSid(), prompt, cwd: tmp }, DEPS));
    assert.ok(!r.block, JSON.stringify(r));
  });
}
caseEnd();

// Driver: same harness shape as tests/bin/feature-2941-workflow-init-driver-pm.js.
const bin = path.join(tmp, "bin");
const repo = path.join(tmp, "repo");
const transcripts = path.join(tmp, "transcripts");
for (const d of [bin, repo, transcripts]) fs.mkdirSync(d);
fs.writeFileSync(path.join(bin, "gh"), "#!/bin/bash\necho 'fake gh: offline' >&2\nexit 1\n", { mode: 0o755 });
gitInit(repo);
function drive(sid) {
  const env = { ...process.env, CLAUDE_CODE_SESSION_ID: sid, CLAUDE_TRANSCRIPT_BASE_DIR: transcripts, NON_GITHUB: "1" };
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  env[key] = `${bin}${path.delimiter}${env[key]}`;
  const r = cp.spawnSync(process.execPath, [path.join(P.ROOT, "bin", "workflow", "workflow-init-driver")], { cwd: repo, env, encoding: "utf8", timeout: 60000 });
  const kv = {};
  for (const line of String(r.stdout || "").split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m && !(m[1] in kv)) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1");
  }
  return { kv, out: `rc=${r.status} stdout=${String(r.stdout).slice(0, 400)} stderr=${String(r.stderr).slice(0, 300)}` };
}
caseBegin("driver-pm-session-undecidable", "bin/workflow/workflow-init-driver");
test("an unreadable state (isPmSession throws) -> ACTION=blocked REASON=pm-session-undecidable", () => {
  const sid = freshSid();
  corrupt(sid);
  const r = drive(sid);
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["blocked", "pm-session-undecidable"], r.out);
});
caseEnd();

// #2942 S7: one issue has one owning PM. /pm-add and /pm-init refuse an issue whose ancestor carries another live
// PM, or whose descendant carries an explicit PM, naming that PM's tag; an accepted change writes the PM field.
// TL3 gap: a real sub-issue tree deeper than the fake gh's nesting cap, or one that needs pagination;
// PM field values a person edited on the board between the check and the write.
const X = require("../lib/pm-s3-fixture");
const { G } = X;
let ooN = 0;
const ooSid = () => P.uuid(0x29420400 + (++ooN));
const ooSeed = (o) => { const s = ooSid(); P.seedPm(s, P.pm(o)); return s; };
const R = (num) => ({ number: num, repo: "o/r" });
// forge(map) — the same PM values reach the writer whether it reads them from gh or from the injected field.
function forge(map) {
  G.setMap(map);
  const seedValues = {};
  for (const [k, v] of Object.entries(map)) if (v.pm) seedValues[k] = v.pm;
  return X.field(seedValues);
}
const refusedNaming = (r, t) => typeof r.block === "string" && r.block.includes(t);

caseBegin("one-owner-per-issue", "hooks/pm-session/writer.js");
test("A1 /pm-add of an issue whose ancestor carries another live PM is refused, naming that PM", () => {
  ooSeed({ tag: "PM-anc1", issues: [] });
  const me = ooSeed({ tag: "PM-me1", issues: [10200] });
  const before = P.readPm(me);
  const f = forge({ "o/r#10201": { parent: R(10202) }, "o/r#10202": { parent: R(10203) }, "o/r#10203": { pm: "PM-anc1" } });
  const r = X.write(me, P.wrapped("pm-add", "#10201 reason"), { pmField: f });
  assert.ok(refusedNaming(r, "PM-anc1"), JSON.stringify(r));
  assert.deepStrictEqual(P.readPm(me), before);
  assert.strictEqual(f.writes.length, 0, JSON.stringify(f.writes));
});
test("A2 /pm-add of an issue whose descendant carries an explicit PM is refused, naming that PM", () => {
  ooSeed({ tag: "PM-desc2", issues: [] });
  const me = ooSeed({ tag: "PM-me2", issues: [10210] });
  const before = P.readPm(me);
  const f = forge({ "o/r#10211": {}, "o/r#10212": { parent: R(10211) }, "o/r#10213": { parent: R(10212), pm: "PM-desc2" } });
  const r = X.write(me, P.wrapped("pm-add", "#10211 reason"), { pmField: f });
  assert.ok(refusedNaming(r, "PM-desc2"), JSON.stringify(r));
  assert.deepStrictEqual(P.readPm(me), before);
  assert.strictEqual(f.writes.length, 0);
});
test("A3 /pm-init with an issue under another live PM is refused the same way; no PM is created", () => {
  ooSeed({ tag: "PM-anc3", issues: [] });
  const me = ooSid();
  P.seedState(me);
  const f = forge({ "o/r#10221": { parent: R(10222) }, "o/r#10222": { pm: "PM-anc3" } });
  const r = X.write(me, P.wrapped("pm-init", "PM-me3 #10221 theme"), { pmField: f });
  assert.ok(refusedNaming(r, "PM-anc3"), JSON.stringify(r));
  assert.ok(!P.readPm(me));
});
test("A4 an ancestor's field naming an ended PM does not block; the issue's field gets this PM's tag", () => {
  ooSeed({ tag: "PM-gone4", issues: [], archived_at: "2026-11-10T00:00:00.000Z" });
  const me = ooSeed({ tag: "PM-me4", issues: [10230] });
  const f = forge({ "o/r#10231": { parent: R(10232) }, "o/r#10232": { pm: "PM-gone4" } });
  const r = X.write(me, P.wrapped("pm-add", "#10231 reason"), { pmField: f });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.deepStrictEqual(f.writes, [{ ref: "o/r#10231", value: "PM-me4" }]);
});
test("A5 no PM above or below: /pm-add writes the field, then the PM state", () => {
  const me = ooSeed({ tag: "PM-me5", issues: [10240] });
  const f = forge({ "o/r#10241": {}, "o/r#10242": { parent: R(10241) } });
  const r = X.write(me, P.wrapped("pm-add", "#10241 reason"), { pmField: f });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.deepStrictEqual(f.writes, [{ ref: "o/r#10241", value: "PM-me5" }]);
  assert.deepStrictEqual(P.readPm(me).issues.map((i) => i.number), [10240, 10241]);
});
test("A6 /pm-remove clears the removed issue's field in the same command", () => {
  const me = ooSeed({ tag: "PM-me6", issues: [10251, 10252] });
  const f = forge({ "o/r#10251": { pm: "PM-me6" }, "o/r#10252": { pm: "PM-me6" } });
  const r = X.write(me, P.wrapped("pm-remove", "#10252 reason"), { pmField: f });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.deepStrictEqual(f.writes, [{ ref: "o/r#10252", value: null }]);
  assert.deepStrictEqual(P.readPm(me).issues.map((i) => i.number), [10251], "the PM state still lists the removed issue");
});
test("A7 /pm-init writes the field of every listed issue with the new tag", () => {
  const me = ooSid();
  P.seedState(me);
  const f = forge({ "o/r#10261": {}, "o/r#10262": {} });
  const r = X.write(me, P.wrapped("pm-init", "PM-me7 #10261 #10262 theme"), { pmField: f });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.deepStrictEqual(f.writes.map((w) => w.ref).sort(), ["o/r#10261", "o/r#10262"]);
  assert.ok(f.writes.every((w) => w.value === "PM-me7"), JSON.stringify(f.writes));
  const pm = P.readPm(me);
  assert.strictEqual(pm.tag, "PM-me7");
  assert.deepStrictEqual(pm.issues.map((i) => i.number).sort(), [10261, 10262], "the PM state does not list every initialized issue");
});
test("A8 the descendant scan failing on the forge refuses (fail-closed), state and field untouched", () => {
  const me = ooSeed({ tag: "PM-me8", issues: [10270] });
  const before = P.readPm(me);
  const f = forge({ "o/r#10271": {} });
  G.mode("fail");
  let r;
  try { r = X.write(me, P.wrapped("pm-add", "#10271 reason"), { pmField: f }); } finally { G.mode(null); }
  assert.ok(typeof r.block === "string" && r.block.length > 0, JSON.stringify(r));
  assert.deepStrictEqual(P.readPm(me), before);
  assert.strictEqual(f.writes.length, 0);
});
caseEnd();

caseBegin("unresolvable-owner-tag-refuses-add", "hooks/pm-session/writer.js");
// No state on this PC holds PM-foreign9, so its owner is undecidable (tag-not-local): /pm-add fails closed.
for (const [where, k, map] of [
  ["the parent's", 10281, { "o/r#10281": { parent: R(10282) }, "o/r#10282": { pm: "PM-foreign9" } }],
  ["the grandparent's", 10291, { "o/r#10291": { parent: R(10292) }, "o/r#10292": { parent: R(10293) }, "o/r#10293": { pm: "PM-foreign9" } }],
]) {
  test(`A9 ${where} PM field holding a tag no local state holds refuses /pm-add with a reason; field and PM state unchanged`, () => {
    const me = ooSeed({ tag: `PM-me9-${++ooN}`, issues: [k - 1] });
    const before = P.readPm(me);
    const f = forge(map);
    const values = Object.assign({}, f.values);
    const r = X.write(me, P.wrapped("pm-add", `#${k} reason`), { pmField: f });
    assert.ok(typeof r.block === "string" && /tag-not-local|PM-foreign9/.test(r.block), JSON.stringify(r));
    assert.strictEqual(f.writes.length, 0, JSON.stringify(f.writes));
    assert.deepStrictEqual(f.values, values);
    assert.deepStrictEqual(P.readPm(me), before);
  });
}
caseEnd();

// #2942: /pm-remove clears only a field that still names this PM (or is empty); another PM's value stays.
caseBegin("pm-remove-clears-only-own-field", "hooks/pm-session/writer.js");
test("B1 /pm-remove leaves a field naming another PM and clears its own", () => {
  const me = ooSeed({ tag: "PM-meB1", issues: [10301, 10302] });
  const f = forge({ "o/r#10301": { pm: "PM-meB1" }, "o/r#10302": { pm: "PM-otherB1" } });
  const r = X.write(me, P.wrapped("pm-remove", "#10301 #10302 reason"), { pmField: f });
  assert.ok(!r.block && !r.threw, JSON.stringify(r));
  assert.deepStrictEqual(f.writes, [{ ref: "o/r#10301", value: null }]);
  assert.strictEqual(f.values["o/r#10302"], "PM-otherB1");
  assert.deepStrictEqual(P.readPm(me).issues, []);
});
test("B2 /pm-remove with an unreadable field refuses; no write, PM state unchanged", () => {
  const me = ooSeed({ tag: "PM-meB2", issues: [10311] });
  const before = P.readPm(me);
  const f = forge({ "o/r#10311": { pm: "PM-meB2" } });
  f.read = () => ({ ok: false, reason: "timeout" });
  const r = X.write(me, P.wrapped("pm-remove", "#10311 reason"), { pmField: f });
  assert.ok(typeof r.block === "string" && /cannot be read/.test(r.block), JSON.stringify(r));
  assert.strictEqual(f.writes.length, 0);
  assert.deepStrictEqual(P.readPm(me), before);
});
caseEnd();

// #2942: an undeterminable origin refuses a PM command that names issues; a non-GitHub origin skips the field.
caseBegin("origin-unknown-refuses-field-io", "hooks/pm-session/writer.js");
test("C1 origin-less checkout + qualified /pm-add refuses with the origin reason; state unchanged", () => {
  // A state dir of its own: the earlier cases' PMs hold bare refs this origin-less cwd cannot scope (repo-unknown).
  const saved = process.env.WORKFLOW_STATE_DIR;
  process.env.WORKFLOW_STATE_DIR = fs.mkdtempSync(path.join(tmp, "c1-state-"));
  try {
    const me = ooSeed({ tag: "PM-meC1", issues: [{ number: 10321, repo: "o/r" }] });
    const before = P.readPm(me);
    const r = call(me, P.wrapped("pm-add", "o/r#10322 reason"));
    assert.ok(typeof r.block === "string" && /origin cannot be determined/.test(r.block), JSON.stringify(r));
    assert.deepStrictEqual(P.readPm(me), before);
  } finally { process.env.WORKFLOW_STATE_DIR = saved; }
});
test("C2 origin-less checkout + bare /pm-add #N reports the unresolved repo first", () => {
  const me = ooSeed({ tag: "PM-meC2", issues: [10331] });
  const r = call(me, P.wrapped("pm-add", "#10332 reason"));
  assert.ok(typeof r.block === "string" && /repo-unresolved/.test(r.block) && !/origin cannot be determined/.test(r.block), JSON.stringify(r));
});
test("C3 fieldIoOf: a GitLab origin -> null (no forge field); no origin -> refusal", () => {
  const O = P.load("hooks/pm-session/ownership.js");
  assert.strictEqual(O.fieldIoOf({ __origin: "https://gitlab.com/a/b.git" }, {}), null);
  assert.throws(() => O.fieldIoOf({ __origin: null }, {}), /origin cannot be determined/);
});
caseEnd();

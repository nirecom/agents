"use strict";
// Fixture of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
// Assumed API: runPmWriter(input, deps) -> {block?, context?, notice?}, input being the UserPromptSubmit
// payload {session_id, prompt, cwd, hook_event_name}; deps.now() -> ms. The forge is the fake gh on this
// process's PATH (../../bin/feature-2941-pm-state-cli/gh-env.js), so the writer's real fetchAncestorChains
// answers from FORGE below; the default cwd is a checkout whose origin is github.com/o/r.
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");
const { after } = require("node:test");
const P = require("../../lib/pm-state-fixture");
const { ghEnv } = require("../../bin/feature-2941-pm-state-cli/gh-env");

const WRITER = "hooks/pm-session/writer.js";
const UNSTATED = "reason not stated";
let n = 0;
const nextSid = () => P.uuid(0x29410000 + (++n));
const nextTag = (base) => `${base || "PM-w"}${++n}`;

// FORGE (o/r): 8000 meta A > 8010 meta B > 8011 C, 8012 D; 8020 meta > 8030 meta; 8040 meta (archived
// holder) > 8041; 8100 plain S > 8101; 8200 label overflow > 8201; 8300 > … > 8311 (11 ancestors);
// 8320 <-> 8321 cycle; 8400 plain > 8401. Every other issue exists with no parent and no label.
const R = (num) => ({ number: num, repo: "o/r" });
const meta = (parent) => ({ parent: parent ? R(parent) : null, labels: ["meta"] });
const plain = (parent) => ({ parent: parent ? R(parent) : null, labels: [] });
const FORGE = {
  "o/r#8000": meta(), "o/r#8010": meta(8000), "o/r#8011": plain(8010), "o/r#8012": plain(8010),
  "o/r#8020": meta(), "o/r#8030": meta(8020), "o/r#8040": meta(), "o/r#8041": plain(8040),
  "o/r#8100": plain(), "o/r#8101": plain(8100), "o/r#8200": { parent: null, labels: ["x"], more: true }, "o/r#8201": plain(8200),
  "o/r#8300": plain(), "o/r#8320": plain(8321), "o/r#8321": plain(8320), "o/r#8400": plain(), "o/r#8401": plain(8400),
};
for (let i = 8301; i <= 8311; i++) FORGE[`o/r#${i}`] = plain(i - 1);

const G = ghEnv("pm-writer-gh-");
G.setMap(FORGE);
const home = fs.mkdtempSync(path.join(os.tmpdir(), "pm-writer-home-"));
for (const args of [["init", "-q"], ["config", "core.hooksPath", "/dev/null"], ["remote", "add", "origin", "https://github.com/o/r.git"]]) {
  const r = cp.spawnSync("git", ["-C", home, ...args], { encoding: "utf8", timeout: 20000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
}
// Windows may refuse to remove home while a test's cwd or a child still holds it (EPERM / EBUSY): the
// cwd is left first, and a still-held tmp dir is left to the OS rather than failing the file.
after(() => { G.restore(); if (path.relative(home, process.cwd()).split(path.sep)[0] !== "..") process.chdir(os.tmpdir()); try { fs.rmSync(home, { recursive: true, force: true, maxRetries: 3 }); } catch (e) { if (process.platform !== "win32" || !["EPERM", "EBUSY"].includes(e.code)) throw e; } });

function writer() {
  const fn = P.load(WRITER).runPmWriter;
  assert.strictEqual(typeof fn, "function", "runPmWriter is not exported as a function");
  return fn;
}
// write(sid, prompt, cwd?) -> the writer result plus calls (gh calls it made) and ms; a throw becomes {threw}.
function write(sid, prompt, cwd) {
  const fn = writer();
  const before = G.calls();
  const t0 = Date.now();
  let r;
  try {
    r = fn({ session_id: sid, hook_event_name: "UserPromptSubmit", prompt, cwd: cwd || home }, { now: () => Date.now() }) || {};
  } catch (e) {
    r = { threw: e.message };
  }
  return Object.assign({}, r, { calls: G.calls() - before, ms: Date.now() - t0 });
}
const blocked = (r) => Boolean(r) && typeof r.block === "string" && r.block.length > 0;
const firstLine = (r) => String((r && r.context) || "").split(/\r?\n/)[0];
const nums = (pmValue) => ((pmValue && pmValue.issues) || []).map((i) => i.number);
const lastLog = (pmValue) => ((pmValue && pmValue.assignment_log) || []).slice(-1)[0] || {};
const brief = (r) => JSON.stringify(r);

function assertBlocked(r) {
  assert.ok(blocked(r), `expected a block, got ${brief(r)}`);
}
function assertAccepted(r, op, tag) {
  assert.ok(!blocked(r) && !r.threw, `expected acceptance, got ${brief(r)}`);
  assert.strictEqual(firstLine(r), `[pm-session] op=${op} tag=${tag}`, brief(r));
}
// assertUntouched(r) — the prompt was not a PM command for the writer: no block, no context.
function assertUntouched(r) {
  writer();
  assert.ok(!blocked(r) && !r.threw && !r.context, brief(r));
}
// archive(sid) — end a PM a case seeded, so its issues stop counting for the cases after it.
function archive(sid) {
  const st = P.raw(sid);
  if (st.pm) st.pm.archived_at = "2026-11-09T00:00:00.000Z";
  P.writeRaw(sid, st);
}
// other(issues, extra) -> {sid, tag} of a fresh active PM (another PM for the case's session).
function other(issues, extra) {
  const sid = nextSid();
  const tag = nextTag("PM-oth");
  P.seedPm(sid, P.pm(Object.assign({ tag, issues }, extra || {})));
  return { sid, tag };
}
// alone(fn) — fn runs against an empty state dir (no other PM at all); the pins come back after.
function alone(fn) {
  const saved = { s: process.env.WORKFLOW_STATE_DIR, p: process.env.WORKFLOW_PLANS_DIR };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pm-writer-alone-"));
  for (const d of ["state", "plans"]) fs.mkdirSync(path.join(dir, d));
  process.env.WORKFLOW_STATE_DIR = path.join(dir, "state");
  process.env.WORKFLOW_PLANS_DIR = path.join(dir, "plans");
  try { return fn(); } finally {
    process.env.WORKFLOW_STATE_DIR = saved.s;
    process.env.WORKFLOW_PLANS_DIR = saved.p;
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = {
  P, G, WRITER, UNSTATED, home, nextSid, nextTag, writer, write, blocked, firstLine, nums, lastLog, brief,
  assertBlocked, assertAccepted, assertUntouched, archive, other, alone,
};

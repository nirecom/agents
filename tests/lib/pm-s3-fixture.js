"use strict";
// Shared pieces of the #2942 PM tests (generation, one-owner, rename, notify). No case markers.
// The fake gh env and the o/r checkout come from tests/hooks/feature-2941-pm-writer/fixture.js.
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("./pm-state-fixture");
const F = require("../hooks/feature-2941-pm-writer/fixture");

const WRITER = path.join(P.ROOT, "hooks", "pm-session", "writer.js");
const lockPath = () => path.join(process.env.WORKFLOW_STATE_DIR, "pm.lock");
const refKey = (r) => `${r.repo || "o/r"}#${r.number}`;

// field() -> an injected PM field ({write, read}) backed by an in-memory map; writes lists every write.
function field(seed) {
  const values = Object.assign({}, seed || {});
  const writes = [];
  return {
    values, writes,
    write: (ref, value) => { writes.push({ ref: refKey(ref), value }); values[refKey(ref)] = value; return { result: "ok" }; },
    read: (refs) => ({ ok: true, values: Object.fromEntries(refs.map((r) => [refKey(r), values[refKey(r)] === undefined ? null : values[refKey(r)]])) }),
  };
}

// write(sid, prompt, deps?) -> the writer result ({block?, context?, notice?} or {threw}), with ms.
function write(sid, prompt, deps) {
  const t0 = Date.now();
  let r;
  try {
    r = P.load("hooks/pm-session/writer.js").runPmWriter({ session_id: sid, hook_event_name: "UserPromptSubmit", prompt, cwd: F.home },
      Object.assign({ now: () => Date.now() }, deps || {})) || {};
  } catch (e) { r = { threw: e.message }; }
  return Object.assign({}, r, { ms: Date.now() - t0 });
}

// cli(argv, caller, deps?) -> {code, out, err, json, ms}: bin/lib/pm-state/cli.js main in process.
function cli(argv, caller, deps) {
  let out = "";
  let err = "";
  const t0 = Date.now();
  let code;
  try {
    code = P.load("bin/lib/pm-state/cli.js").main(argv, Object.assign({
      callerSessionId: caller, resolveOwnerRepoFromOrigin: () => ({ ok: true, ownerRepo: "o/r" }),
      out: (s) => { out += s; }, err: (s) => { err += s; },
    }, deps || {}));
  } catch (e) { code = -1; err += e.message; }
  let json;
  try { json = JSON.parse(out.trim()); } catch (_) { json = undefined; }
  return { code, out, err, json, ms: Date.now() - t0 };
}

// childWrite(sid, prompt) -> the writer result of a separate node process (a competitor that takes the PM lock itself).
function childWrite(sid, prompt) {
  const code = "const w=require(process.argv[1]);let r;try{r=w.runPmWriter({session_id:process.argv[2],hook_event_name:'UserPromptSubmit',prompt:process.argv[3],cwd:process.argv[4]},{now:()=>Date.now()})||{}}catch(e){r={threw:e.message}}process.stdout.write(JSON.stringify(r))";
  const r = cp.spawnSync(process.execPath, ["-e", code, WRITER, sid, prompt, F.home], { encoding: "utf8", timeout: 30000, env: process.env });
  try { return JSON.parse(r.stdout); } catch (_) { return { threw: `child: ${r.stdout}${r.stderr}` }; }
}

// holdLock(o) -> {pid, release()}: a live node process holding <state root>/pm.lock (fresh `at` unless o.ageMs).
function holdLock(o = {}) {
  const f = lockPath();
  const code = "const fs=require('fs');const f=process.argv[1];const age=Number(process.argv[2]);fs.writeFileSync(f,JSON.stringify({pid:process.pid,start_ms:Date.now()-process.uptime()*1000,token:'held-'+process.pid,host:require('os').hostname(),at:new Date(Date.now()-age).toISOString()}));setTimeout(()=>{try{fs.rmSync(f)}catch(_){}process.exit(0)},15000)";
  const child = cp.spawn(process.execPath, ["-e", code, f, String(o.ageMs || 0)], { stdio: "ignore", env: process.env });
  const until = Date.now() + 10000;
  while (!fs.existsSync(f) && Date.now() < until) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
  if (!fs.existsSync(f)) throw new Error("the lock holder did not start");
  return { pid: child.pid, release: () => { try { child.kill(); } catch (_) { /* gone */ } fs.rmSync(f, { force: true }); } };
}

// seqFile(obj) -> a temp set-sequence payload file.
let seqN = 0;
function seqFile(obj) {
  const f = path.join(os.tmpdir(), `pm-s3-seq-${process.pid}-${++seqN}.json`);
  fs.writeFileSync(f, JSON.stringify(obj));
  return f;
}
const table = (nums) => ({ tables: [{ title: "order", waves: [{ issues: nums.map((number) => ({ number, reason: "fixture", blocked_by: [], conflicts: [] })) }] }] });
const unstatedLog = (nums) => [{ at: "2026-11-01T00:00:00.000Z", op: "init", issues: nums.map((n) => ({ number: n })), reason: F.UNSTATED }];

// notify(argv, o) -> {code, out, err, kv}: bin/pm-notify spawned from the o/r checkout (o.cwd) as session o.sid;
// kv holds the KEY=VALUE lines of stdout (the last one wins), lines every stdout line.
const transcripts = fs.mkdtempSync(path.join(os.tmpdir(), "pm-s3-transcripts-"));
const notifyHome = fs.mkdtempSync(path.join(os.tmpdir(), "pm-s3-home-"));
require("node:test").after(() => { for (const d of [transcripts, notifyHome]) fs.rmSync(d, { recursive: true, force: true }); });
function notify(argv, o = {}) {
  // bin/pm-notify never reads the home dir today; pin HOME anyway so a future default root stays in the fixture.
  const env = Object.assign({}, process.env, { CLAUDE_TRANSCRIPT_BASE_DIR: transcripts, HOME: notifyHome, USERPROFILE: notifyHome }, o.env || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  if (o.sid) env.CLAUDE_CODE_SESSION_ID = o.sid;
  const t0 = Date.now();
  const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', P.fwd(path.join(P.ROOT, "bin", "pm-notify")), ...argv], { cwd: o.cwd || F.home, env, encoding: "utf8", timeout: 60000 });
  const out = String(r.stdout || "");
  const lines = out.split(/\r?\n/).filter(Boolean);
  const kv = {};
  for (const l of lines) { const m = /^([A-Z_]+)=(.*)$/.exec(l); if (m) kv[m[1]] = m[2]; }
  return { code: r.status, out, err: String(r.stderr || ""), kv, lines, ms: Date.now() - t0 };
}

// The mailbox files: <state root>/pm-mailbox/<tag>.jsonl and unassigned.jsonl (one JSON object per line).
const boxPath = (name) => path.join(process.env.WORKFLOW_STATE_DIR, "pm-mailbox", `${name}.jsonl`);
const readBox = (name) => (fs.existsSync(boxPath(name)) ? fs.readFileSync(boxPath(name), "utf8").split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l)) : []);
function writeBox(name, entries) {
  fs.mkdirSync(path.dirname(boxPath(name)), { recursive: true });
  fs.writeFileSync(boxPath(name), entries.map((e) => `${JSON.stringify(e)}\n`).join(""));
}
const notes = (sid) => (P.raw(sid).pm_notifications || []);

module.exports = {
  P, F, G: F.G, lockPath, refKey, field, write, cli, childWrite, holdLock, seqFile, table, unstatedLog,
  notify, boxPath, readBox, writeBox, notes,
};

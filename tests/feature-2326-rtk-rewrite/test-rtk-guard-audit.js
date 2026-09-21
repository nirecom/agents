#!/usr/bin/env node
"use strict";
// tests/feature-2326-rtk-rewrite/test-rtk-guard-audit.js
// No-framework Node tests for the NEW hooks/lib/rtk-guard-audit.js writer +
// file-lock rotation. TEST-FIRST: the module does not exist yet, so require()
// fails and every case reports RED (module not loaded). All log/lock paths are
// injected under a temp dir — never the real $HOME. Spec: detail plan §3/§5.

const path = require("path");
const fs = require("fs");
const os = require("os");
const assert = require("assert");
const { spawn } = require("child_process");

const MODULE = path.join(__dirname, "..", "..", "hooks", "lib", "rtk-guard-audit.js");
let mod = null;
let loadErr = null;
try { mod = require(MODULE); } catch (e) { loadErr = e; }

let pass = 0;
let fail = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: ${name}`); pass++; }
  catch (e) { console.log(`FAIL: ${name} — ${e.message}`); fail++; }
}
function requireMod() {
  if (!mod) throw new Error(`module not loaded: ${(loadErr && loadErr.code) || loadErr}`);
  return mod;
}
function mkTmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

// --- Writer: one JSONL line with v/ts/guard/action/command. ---
check("writer: one JSONL line with fields v/ts/guard/action/command", () => {
  const m = requireMod();
  const dir = mkTmp("rtkga-basic-");
  const logPath = path.join(dir, "guard.log");
  const NOW = 1727000000000;
  m.recordGuardReject("machineReadable", "git rev-parse HEAD",
    { logPath, lockPath: logPath + ".lock", now: () => NOW });
  const lines = fs.readFileSync(logPath, "utf8").split(/\n/).filter(Boolean);
  assert.strictEqual(lines.length, 1, "exactly one line written");
  const rec = JSON.parse(lines[0]);
  assert.strictEqual(rec.v, m.LOG_FORMAT_VERSION, "v = LOG_FORMAT_VERSION");
  assert.strictEqual(rec.v, 1, "LOG_FORMAT_VERSION is 1");
  assert.strictEqual(rec.guard, "machineReadable");
  assert.strictEqual(rec.action, "reject");
  assert.strictEqual(rec.command, "git rev-parse HEAD");
  assert.strictEqual(rec.ts, new Date(NOW).toISOString(), "ts reflects injected now");
});

// --- resolveLogPath: injected logPath wins. ---
check("resolveLogPath: opts.logPath injection wins", () => {
  const m = requireMod();
  const p = path.join(os.tmpdir(), "explicit-rtkga", "guard.log");
  assert.strictEqual(m.resolveLogPath({ logPath: p }), p);
});

// --- Rotation: MAX_BYTES overflow renames base→.1, shifts, drops oldest. ---
check("rotation: overflow rotates base→.1, shifts .1→.2/.2→.3, drops beyond MAX_ROTATED", () => {
  const m = requireMod();
  assert.strictEqual(m.MAX_ROTATED, 3, "MAX_ROTATED is 3");
  const dir = mkTmp("rtkga-rot-");
  const logPath = path.join(dir, "guard.log");
  const MAX = m.MAX_BYTES;
  // Pre-fill base to exactly MAX bytes so the next record overflows.
  fs.writeFileSync(logPath, Buffer.alloc(MAX, 0x61)); // 'a' * MAX
  fs.writeFileSync(logPath + ".1", "R1\n");
  fs.writeFileSync(logPath + ".2", "R2\n");
  fs.writeFileSync(logPath + ".3", "R3\n");
  m.recordGuardReject("g", "trigger", { logPath, lockPath: logPath + ".lock", now: () => 1 });
  const baseLines = fs.readFileSync(logPath, "utf8").split(/\n/).filter(Boolean);
  assert.strictEqual(baseLines.length, 1, "fresh base holds only the new record");
  assert.strictEqual(JSON.parse(baseLines[0]).command, "trigger");
  assert.strictEqual(fs.statSync(logPath + ".1").size, MAX, "old base rotated to .1");
  assert.strictEqual(fs.readFileSync(logPath + ".2", "utf8"), "R1\n", "old .1 shifted to .2");
  assert.strictEqual(fs.readFileSync(logPath + ".3", "utf8"), "R2\n", "old .2 shifted to .3");
  assert.ok(!fs.existsSync(logPath + ".4"), "no .4 (oldest beyond MAX_ROTATED dropped)");
});

// --- Fail-open: writer-internal exception is swallowed, never thrown. ---
check("writer: internal exception is swallowed (never thrown to caller)", () => {
  const m = requireMod();
  const dir = mkTmp("rtkga-swallow-");
  const blocker = path.join(dir, "blocker");
  fs.writeFileSync(blocker, "x"); // a file, not a dir
  const logPath = path.join(blocker, "nested", "guard.log"); // parent is a file → mkdir fails
  assert.doesNotThrow(() => {
    m.recordGuardReject("g", "cmd", { logPath, lockPath: logPath + ".lock", now: () => 1 });
  });
  assert.ok(!fs.existsSync(logPath), "no log created under an unwritable path");
});

// --- Lock: stale lock (old mtime) stolen quickly (C2-iii). ---
check("lock: stale lock (old mtime) is stolen and the record is written", () => {
  const m = requireMod();
  const dir = mkTmp("rtkga-stale-");
  const logPath = path.join(dir, "guard.log");
  const lockPath = logPath + ".lock";
  fs.writeFileSync(lockPath, String(process.pid));
  const oldSec = Date.now() / 1000 - 3600; // 1h ago; well past LOCK_STALE_MS
  fs.utimesSync(lockPath, oldSec, oldSec);
  const t0 = Date.now();
  m.recordGuardReject("g", "stale-steal", { logPath, lockPath });
  const dt = Date.now() - t0;
  assert.ok(fs.existsSync(logPath), "record written after stealing stale lock");
  assert.strictEqual(JSON.parse(fs.readFileSync(logPath, "utf8").trim()).command, "stale-steal");
  assert.ok(dt < m.LOCK_STALE_MS, `stale steal is fast (dt=${dt} < ${m.LOCK_STALE_MS})`);
  assert.ok(!fs.existsSync(lockPath), "lock released after writing");
});

// --- Lock: fresh lock forces a bounded wait, then steal past LOCK_STALE_MS (C2-iv). ---
check("lock: fresh lock → wait past LOCK_STALE_MS then steal and proceed", () => {
  const m = requireMod();
  const dir = mkTmp("rtkga-wait-");
  const logPath = path.join(dir, "guard.log");
  const lockPath = logPath + ".lock";
  fs.writeFileSync(lockPath, "holder"); // fresh mtime = now
  const t0 = Date.now();
  m.recordGuardReject("g", "wait-steal", { logPath, lockPath });
  const dt = Date.now() - t0;
  assert.ok(fs.existsSync(logPath), "record eventually written");
  assert.strictEqual(JSON.parse(fs.readFileSync(logPath, "utf8").trim()).command, "wait-steal");
  assert.ok(dt >= m.LOCK_STALE_MS - 250, `waited ~LOCK_STALE_MS before steal (dt=${dt})`);
});

// --- Concurrency (C2): N workers × M records cross a rotation boundary. ---
function gatherIds(dir, baseName) {
  const ids = [];
  for (const f of fs.readdirSync(dir)) {
    if (f.endsWith(".lock")) continue;
    if (f !== baseName && !f.startsWith(baseName + ".")) continue;
    const raw = fs.readFileSync(path.join(dir, f), "utf8");
    for (const line of raw.split(/\n/)) {
      const s = line.trim();
      if (!s) continue;
      let rec;
      try { rec = JSON.parse(s); } catch (_e) { continue; }
      if (rec && typeof rec.command === "string") ids.push(rec.command.split(" ")[0]);
    }
  }
  return ids;
}
async function concurrencyTest() {
  const name = "concurrency: N×M records cross rotation with zero loss/dup, no deadlock";
  try {
    requireMod(); // RED fast when the module is missing (no workers spawned)
    const dir = mkTmp("rtkga-conc-");
    const logPath = path.join(dir, "guard.log");
    const lockPath = logPath + ".lock";
    const N = 4;
    const M = 150;
    // 2 KB padding per record → N*M ≈ 1.2 MB > MAX_BYTES, forcing ≥1 rotation.
    const code =
      "const mod=require(process.argv[1]);const wid=process.argv[2];" +
      "const count=Number(process.argv[3]);const logPath=process.argv[4];" +
      "const lockPath=process.argv[5];const pad='x'.repeat(2000);" +
      "for(let i=0;i<count;i++){mod.recordGuardReject('gConc','W'+wid+'#'+i+' '+pad," +
      "{logPath:logPath,lockPath:lockPath});}";
    const spawnWorker = (wid) => new Promise((resolve) => {
      const child = spawn(process.execPath,
        ["-e", code, MODULE, String(wid), String(M), logPath, lockPath],
        { stdio: "ignore" });
      child.on("exit", (c) => resolve(c === null ? -1 : c));
      child.on("error", () => resolve(-1));
    });
    const deadline = new Promise((_res, rej) =>
      setTimeout(() => rej(new Error("concurrency deadline exceeded (possible deadlock)")), 90000));
    const codes = await Promise.race([
      Promise.all(Array.from({ length: N }, (_v, i) => spawnWorker(i))),
      deadline,
    ]);
    assert.ok(codes.every((c) => c === 0), `all workers exit 0 — no deadlock (got ${JSON.stringify(codes)})`);
    const ids = gatherIds(dir, "guard.log").sort();
    const expected = [];
    for (let w = 0; w < N; w++) for (let i = 0; i < M; i++) expected.push("W" + w + "#" + i);
    expected.sort();
    assert.strictEqual(ids.length, expected.length, `record count ${ids.length} === ${expected.length}`);
    assert.deepStrictEqual(ids, expected, "every submitted record present exactly once (no loss/dup)");
    assert.ok(fs.existsSync(logPath + ".1"), "rotation boundary was crossed (.1 exists)");
    console.log(`PASS: ${name}`); pass++;
  } catch (e) {
    console.log(`FAIL: ${name} — ${e.message}`); fail++;
  }
}

(async () => {
  await concurrencyTest();
  console.log("----");
  console.log(`PASS=${pass} FAIL=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();

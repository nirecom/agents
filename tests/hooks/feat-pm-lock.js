"use strict";
// Tests: hooks/pm-session/pm-lock.js, hooks/lib/process-start-time.js, hooks/pm-session/writer-common.js
// Tags: TL1, scope:common, pm-session, pm-lock, issue-2942
// #2942 S7: the PC-wide PM lock and its holder liveness (outline decision 3, detail "pm-lock.js").
// Assumed API (the detail fixes the behaviour, these names are the test's reading of it):
//   pm-lock.js: withPmLock(fn, {waitMs, startTimeOf?}) -> fn's value, or a refusal thrown (or returned)
//     with reason "pm-lock-busy"; PM_LOCK_STALE_MS. Lock file: <WORKFLOW_STATE_DIR>/pm.lock.
//   process-start-time.js: startTimeOf(pid, {timeoutMs, platform?, spawnSync?, readFileSync?}) ->
//     {ok:true, ms} | {ok:false, reason}; selfStartTimeMs(). Linux uses CLK_TCK 100.
const { test, after } = require("node:test");
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
after(restore);
const LOCK = require("../lib/pm-state-fixture").load("hooks/pm-session/pm-lock.js");
const PST = P.load("hooks/lib/process-start-time.js");
const lockFile = () => path.join(process.env.WORKFLOW_STATE_DIR, "pm.lock");
const RAN = "fn-ran";

// attempt(opts) -> {ran, refusal, ms}: withPmLock with an fn that only marks it ran.
function attempt(opts) {
  const t0 = Date.now();
  let ran = false;
  let refusal = null;
  try {
    const r = LOCK.withPmLock(() => { ran = true; return RAN; }, opts);
    if (r !== RAN) refusal = r;
  } catch (e) {
    refusal = e;
  }
  return { ran, refusal, ms: Date.now() - t0 };
}
const text = (refusal) => `${refusal && refusal.reason} ${refusal && refusal.message} ${refusal && refusal.stdout ? refusal.stdout : ""}`;
function assertBusy(r) {
  assert.strictEqual(r.ran, false, "fn ran while another holder kept the lock");
  assert.ok(r.refusal, "no refusal");
  assert.match(text(r.refusal), /pm-lock-busy/, text(r.refusal));
}
// holder(o) — writes a lock file as another process would; ageMs back-dates `at` and the mtime.
function holder(o) {
  const at = new Date(Date.now() - (o.ageMs || 0));
  const payload = { pid: o.pid, start_ms: o.start_ms, token: o.token || "11111111-2222-4333-8444-555555555555", host: os.hostname(), at: at.toISOString() };
  fs.writeFileSync(lockFile(), JSON.stringify(payload));
  fs.utimesSync(lockFile(), at, at);
  return payload;
}
const deadPid = () => cp.spawnSync(process.execPath, ["-e", "0"]).pid;
const clear = () => fs.rmSync(lockFile(), { force: true });
const START = 1763600000000;
const matching = () => ({ ok: true, ms: START + 500 });

caseBegin("pm-lock-liveness-and-steal", "hooks/pm-session/pm-lock.js");
test("L1 a free lock runs fn, writes {pid,start_ms,token,host,at} while held, and is gone after", () => {
  clear();
  let seen = null;
  const r = LOCK.withPmLock(() => { seen = JSON.parse(fs.readFileSync(lockFile(), "utf8")); return RAN; }, { waitMs: 200 });
  assert.strictEqual(r, RAN);
  assert.strictEqual(seen.pid, process.pid);
  assert.match(String(seen.token), /^[0-9a-f-]{36}$/);
  assert.strictEqual(seen.host, os.hostname());
  assert.ok(Math.abs(seen.start_ms - (Date.now() - process.uptime() * 1000)) < 5000, JSON.stringify(seen));
  assert.ok(!Number.isNaN(Date.parse(seen.at)), JSON.stringify(seen));
  assert.strictEqual(fs.existsSync(lockFile()), false, "lock left behind");
});
test("L1 the lock is released when fn throws", () => {
  clear();
  assert.throws(() => LOCK.withPmLock(() => { throw new Error("boom-in-fn"); }, { waitMs: 200 }), /boom-in-fn/);
  assert.strictEqual(fs.existsSync(lockFile()), false, "lock left behind after a throw");
});
test("L2 a live holder whose start time matches is never stolen, even past PM_LOCK_STALE_MS: refusal names HOLDER_PID, HOLDER_AGE_MS, the path and the release steps", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 20000 });
  const r = attempt({ waitMs: 3000, startTimeOf: matching });
  assertBusy(r);
  const t = text(r.refusal);
  assert.match(t, new RegExp(`HOLDER_PID=${process.pid}\\b`), t);
  assert.match(t, /HOLDER_AGE_MS=\d+/, t);
  assert.ok(t.includes(lockFile()) || t.includes(P.fwd(lockFile())), t);
  for (const step of ["Get-Process", "Stop-Process", "Remove-Item"]) assert.ok(t.includes(step), `${step} missing: ${t}`);
  assert.ok(r.ms < 1500, `past the stale threshold the refusal must not wait (${r.ms} ms)`);
  assert.strictEqual(JSON.parse(fs.readFileSync(lockFile(), "utf8")).pid, process.pid, "the live holder's lock was replaced");
  clear();
});
test("L3 a live fresh holder: waits up to waitMs, then refuses with pm-lock-busy", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  const r = attempt({ waitMs: 400, startTimeOf: matching });
  assertBusy(r);
  assert.ok(r.ms >= 350, `refused before waitMs (${r.ms} ms)`);
  clear();
});
test("L3 a holder that releases within waitMs lets fn run", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  const killer = cp.spawn(process.execPath, ["-e", `setTimeout(()=>require("fs").rmSync(${JSON.stringify(lockFile())},{force:true}),300)`], { stdio: "ignore" });
  const r = attempt({ waitMs: 1500, startTimeOf: matching });
  killer.kill();
  assert.strictEqual(r.ran, true, `fn did not run: ${text(r.refusal)}`);
});
test("L4 a dead holder pid is stolen", () => {
  clear();
  holder({ pid: deadPid(), start_ms: START, ageMs: 0 });
  const r = attempt({ waitMs: 200, startTimeOf: matching });
  assert.strictEqual(r.ran, true, `dead holder not stolen: ${text(r.refusal)}`);
});
test("L5 a live pid whose start time differs by more than 2000 ms (pid reuse) is stolen", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  const r = attempt({ waitMs: 200, startTimeOf: () => ({ ok: true, ms: START + 2500 }) });
  assert.strictEqual(r.ran, true, `reused pid not stolen: ${text(r.refusal)}`);
});
test("L5 control: a start time within 2000 ms keeps the holder live", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  assertBusy(attempt({ waitMs: 200, startTimeOf: () => ({ ok: true, ms: START + 1900 }) }));
  clear();
});
test("L6 an unreadable start time (timeout) counts as live: not stolen", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  assertBusy(attempt({ waitMs: 200, startTimeOf: () => ({ ok: false, reason: "timeout" }) }));
  assert.strictEqual(JSON.parse(fs.readFileSync(lockFile(), "utf8")).start_ms, START);
  clear();
});
test("L7 a lock re-created by another process (other token) between the judgment and the steal is not stolen", () => {
  clear();
  holder({ pid: process.pid, start_ms: START, ageMs: 0 });
  const NEW_TOKEN = "99999999-8888-4777-8666-555555555555";
  let calls = 0;
  const startTimeOf = () => {
    calls += 1;
    if (calls === 1) {
      holder({ pid: process.pid, start_ms: START + 10, token: NEW_TOKEN, ageMs: 0 });
      return { ok: true, ms: START + 9000 };
    }
    return { ok: true, ms: START + 10 };
  };
  const r = attempt({ waitMs: 300, startTimeOf });
  assertBusy(r);
  assert.strictEqual(JSON.parse(fs.readFileSync(lockFile(), "utf8")).token, NEW_TOKEN, "the re-created lock was taken");
  clear();
});
caseEnd();

caseBegin("pm-lock-budget-invariant", "hooks/pm-session/writer-common.js");
test("B1 PM_LOCK_STALE_MS (15000) exceeds WRITER_CHECK_BUDGET_MS + WRITER_WRITE_BUDGET_MS (3000 + 5000)", () => {
  const WC = P.load("hooks/pm-session/writer-common.js");
  assert.strictEqual(LOCK.PM_LOCK_STALE_MS, 15000);
  assert.strictEqual(WC.WRITER_CHECK_BUDGET_MS, 3000);
  assert.strictEqual(WC.WRITER_WRITE_BUDGET_MS, 5000);
  assert.ok(LOCK.PM_LOCK_STALE_MS > WC.WRITER_CHECK_BUDGET_MS + WC.WRITER_WRITE_BUDGET_MS);
  assert.ok(1500 + WC.WRITER_CHECK_BUDGET_MS + WC.WRITER_WRITE_BUDGET_MS < 10000, "lock wait + forge budgets must fit the 10 s hook");
  assert.strictEqual(WC.WRITER_FORGE_BUDGET_MS, undefined, "the old budget name must be gone");
});
caseEnd();

caseBegin("process-start-time-per-os", "hooks/lib/process-start-time.js");
// fakeSpawn(stdout, sink) -> a spawnSync stand-in that records [cmd, args, opts] and answers stdout.
const fakeSpawn = (stdout, sink, extra) => (cmd, args, opts) => { sink.push([cmd, args, opts]); return Object.assign({ status: 0, stdout, stderr: "" }, extra || {}); };
test("S1 linux reads /proc/<pid>/stat field 22 and /proc/stat btime (CLK_TCK 100), no spawn", () => {
  const spawned = [];
  const files = { "/proc/4242/stat": "4242 (my proc) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 12345 0 0", "/proc/stat": "cpu 1 2 3\nbtime 1763600000\nprocesses 9\n" };
  const r = PST.startTimeOf(4242, { timeoutMs: 1000, platform: "linux", spawnSync: fakeSpawn("", spawned), readFileSync: (f) => { if (!(f in files)) throw new Error(`ENOENT ${f}`); return files[f]; } });
  assert.deepStrictEqual(r, { ok: true, ms: 1763600000 * 1000 + 12345 * 10 });
  assert.strictEqual(spawned.length, 0);
});
test("S2 darwin runs ps -o lstart= -p <pid> with the timeout and parses the date", () => {
  const spawned = [];
  const r = PST.startTimeOf(4243, { timeoutMs: 1000, platform: "darwin", spawnSync: fakeSpawn("Thu Nov 20 10:00:00 2026\n", spawned), readFileSync: () => { throw new Error("no /proc"); } });
  assert.deepStrictEqual(r, { ok: true, ms: new Date("Thu Nov 20 10:00:00 2026").getTime() });
  assert.strictEqual(spawned[0][0], "ps");
  assert.ok(spawned[0][1].includes("lstart=") && spawned[0][1].includes("4243"), JSON.stringify(spawned[0][1]));
  assert.strictEqual(spawned[0][2].timeout, 1000);
});
test("S3 win32 runs powershell -NoProfile Get-Process -Id <pid> StartTime with the timeout", () => {
  const spawned = [];
  const r = PST.startTimeOf(4244, { timeoutMs: 1000, platform: "win32", spawnSync: fakeSpawn("2026-11-20T01:02:03.4560000Z\r\n", spawned), readFileSync: () => { throw new Error("no /proc"); } });
  assert.deepStrictEqual(r, { ok: true, ms: Date.parse("2026-11-20T01:02:03.456Z") });
  assert.match(String(spawned[0][0]), /powershell/i);
  const argv = spawned[0][1].join(" ");
  for (const part of ["-NoProfile", "Get-Process", "4244", "StartTime"]) assert.ok(argv.includes(part), `${part} missing: ${argv}`);
  assert.strictEqual(spawned[0][2].timeout, 1000);
});
for (const [label, extra] of [["a timed-out spawn", { status: null, error: Object.assign(new Error("spawnSync ETIMEDOUT"), { code: "ETIMEDOUT" }) }], ["a non-zero exit (no such process)", { status: 1, stdout: "" }], ["unparsable output", { status: 0, stdout: "not a date" }]]) {
  test(`S4 win32 ${label} -> {ok:false, reason}`, () => {
    const r = PST.startTimeOf(4245, { timeoutMs: 1000, platform: "win32", spawnSync: fakeSpawn("", [], extra), readFileSync: () => { throw new Error("no /proc"); } });
    assert.strictEqual(r.ok, false, JSON.stringify(r));
    assert.ok(typeof r.reason === "string" && r.reason.length > 0, JSON.stringify(r));
  });
}
test("S5 selfStartTimeMs() is now - uptime and spawns nothing", () => {
  const real = cp.spawnSync;
  cp.spawnSync = () => { throw new Error("selfStartTimeMs spawned a process"); };
  try {
    const got = PST.selfStartTimeMs();
    assert.ok(Math.abs(got - (Date.now() - process.uptime() * 1000)) < 200, String(got));
  } finally { cp.spawnSync = real; }
});
caseEnd();

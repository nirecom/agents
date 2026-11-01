#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io/state-lock.js
// Tags: TL1, workflow-state, state-lock, stale-lock-reclaim, regression-2652, scope:issue-specific, pwsh-not-required
// #2652: acquire() reclaims only a lock judged stale on an unchanged snapshot, never a vanished or replaced one.
// The races are driven in-process by stubbing fs / process.platform around withStateLockAt.
// TL3 gap: real Windows delete-pending EPERM is not reproduced here (EPERM is injected via a stubbed fs.openSync).

const { after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restoreEnv = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2652l-"));
after(() => {
  restoreEnv();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const { check, eq, show } = require("./feature-2652-state-handoff/check");
const ROOT = path.resolve(__dirname, "..", "..");
const L = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "state-lock"));
const HOST = os.hostname();
const SHORT = 80;

let n = 0;
const freshLock = () => path.join(SCRATCH, `l${++n}`, "state.json.lock");
const payload = (over) => JSON.stringify(Object.assign({ pid: process.pid, host: HOST, at: new Date().toISOString() }, over));
function seed(lockPath, text, ageMs) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  fs.writeFileSync(lockPath, text);
  if (ageMs) {
    const t = new Date(Date.now() - ageMs);
    fs.utimesSync(lockPath, t, t);
  }
}
const same = (a, b) => path.resolve(a) === path.resolve(b);

// stub(overrides, fn): installs { "fs.openSync": impl(real, ...args), "platform": "win32" } for fn's duration.
// Also records every fs.unlinkSync path the module issues.
function stub(overrides, fn) {
  const saved = [];
  const unlinked = [];
  const put = (obj, key, value) => { saved.push([obj, key, Object.getOwnPropertyDescriptor(obj, key)]); Object.defineProperty(obj, key, value); };
  const realUnlink = fs.unlinkSync;
  put(fs, "unlinkSync", { value: (p, ...rest) => { unlinked.push(p); return realUnlink.call(fs, p, ...rest); }, configurable: true, writable: true });
  for (const [key, impl] of Object.entries(overrides)) {
    if (key === "platform") { put(process, "platform", { value: impl, configurable: true }); continue; }
    const name = key.replace(/^fs\./, "");
    const real = fs[name];
    put(fs, name, { value: (...args) => impl(real.bind(fs), ...args), configurable: true, writable: true });
  }
  try {
    return { result: fn(), unlinked };
  } catch (e) {
    e.unlinked = unlinked;
    throw e;
  } finally {
    for (const [obj, key, desc] of saved.reverse()) Object.defineProperty(obj, key, desc);
  }
}
function expectThrow(fn, want) {
  try { fn(); } catch (e) { if (!want(e)) throw new Error(`unexpected error: ${e && e.name} ${e && e.code} ${e && e.message}`, { cause: e }); return e; }
  throw new Error("did not throw");
}
const isTimeout = (e) => e instanceof L.StateLockTimeoutError;
const errno = (code) => Object.assign(new Error(`${code}: injected`), { code });
const ownPayloadIn = (lockPath) => () => JSON.parse(fs.readFileSync(lockPath, "utf8"));

// --- 1. vanished between openSync EEXIST and the stat: no unlink, a successor's lock survives ---
caseBegin("vanished-lock-is-not-unlinked", "hooks/workflow-state/state-io/state-lock.js");
check("vanished: lock gone at stat -> no unlink, openSync retried, acquire succeeds", () => {
  const lock = freshLock();
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  let opens = 0;
  const { result, unlinked } = stub({
    "fs.openSync": (real, p, flags) => { if (same(p, lock) && ++opens === 1) throw errno("EEXIST"); return real(p, flags); },
  }, () => L.withStateLockAt(lock, ownPayloadIn(lock), { timeoutMs: SHORT }));
  eq(opens, 2, "openSync calls on the lock");
  eq([result.pid, result.host], [process.pid, HOST], "payload written by the retry");
  eq(unlinked.filter((p) => same(p, lock)).length, 1, "unlinks (only the release)");
});
check("vanished: a successor creates its lock right after the stat -> the waiter never deletes it", () => {
  const lock = freshLock();
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const successor = payload({ at: "successor" });
  let opens = 0;
  let fired = false;
  const e = expectThrow(() => stub({
    "fs.openSync": (real, p, flags) => { if (same(p, lock) && ++opens === 1) throw errno("EEXIST"); return real(p, flags); },
    "fs.statSync": (real, p, ...rest) => {
      if (same(p, lock) && !fired) { fired = true; fs.writeFileSync(lock, successor); throw errno("ENOENT"); }
      return real(p, ...rest);
    },
  }, () => L.withStateLockAt(lock, () => "acquired", { timeoutMs: SHORT })), isTimeout);
  eq(fired, true, "injection fired");
  eq(e.unlinked.filter((p) => same(p, lock)), [], "unlinkSync calls on the lock");
  eq(fs.readFileSync(lock, "utf8"), successor, "successor lock");
});
caseEnd();

// --- 2. stale on the judgment snapshot, replaced before the unlink: no unlink ---
caseBegin("replaced-lock-is-not-unlinked", "hooks/workflow-state/state-io/state-lock.js");
// replaceAtRecheck(lock, mutate): mutates the lock at the second stat (the re-check snapshot) only.
function replaceAtRecheck(lock, mutate) {
  let stats = 0;
  return {
    "fs.statSync": (real, p, ...rest) => { if (same(p, lock) && ++stats === 2) mutate(); return real(p, ...rest); },
    get stats() { return stats; },
  };
}
const replacements = [
  ["age-stale, replaced by a different payload", () => payload({ pid: 999999, host: "other.example.invalid" }), 2 * L.STALE_MS,
    (lock, text) => fs.writeFileSync(lock, text)],
  ["age-stale, same bytes but mtime refreshed", (orig) => orig, 2 * L.STALE_MS,
    (lock) => { const t = new Date(); fs.utimesSync(lock, t, t); }],
];
for (const [label, nextText, age, mutate] of replacements) {
  check(`snapshot mismatch (${label}) -> not unlinked, times out, replacement intact`, () => {
    const lock = freshLock();
    const orig = payload({ host: "other.example.invalid" });
    seed(lock, orig, age);
    const text = nextText(orig);
    const s = replaceAtRecheck(lock, () => mutate(lock, text));
    const e = expectThrow(() => stub({ "fs.statSync": s["fs.statSync"] }, () => L.withStateLockAt(lock, () => 1, { timeoutMs: SHORT })), isTimeout);
    if (s.stats < 2) throw new Error(`fixture: re-check stat never reached (${s.stats})`);
    eq(e.unlinked.filter((p) => same(p, lock)), [], "unlinkSync calls on the lock");
    eq(fs.readFileSync(lock, "utf8"), text, "replacement lock");
    if (Date.now() - fs.statSync(lock).mtimeMs > L.STALE_MS) throw new Error("replacement lock is not the fresh one");
  });
}
check("snapshot mismatch, then the new holder releases -> acquired without the waiter unlinking it", () => {
  const lock = freshLock();
  seed(lock, payload({ host: "other.example.invalid" }), 2 * L.STALE_MS);
  const replacement = payload({ at: "replacement" });
  const s = replaceAtRecheck(lock, () => fs.writeFileSync(lock, replacement));
  const realUnlink = fs.unlinkSync;
  let opens = 0;
  const { result, unlinked } = stub({
    "fs.statSync": s["fs.statSync"],
    "fs.openSync": (real, p, flags) => { if (same(p, lock) && ++opens === 3) realUnlink.call(fs, lock); return real(p, flags); },
  }, () => L.withStateLockAt(lock, ownPayloadIn(lock), { timeoutMs: 2000 }));
  eq(opens, 3, "openSync calls");
  eq([result.pid, result.host, result.at === "replacement"], [process.pid, HOST, false], "payload after acquire");
  eq(unlinked.filter((p) => same(p, lock)).length, 1, "unlinks (only the release)");
});
caseEnd();

// --- 3. reclaim success paths ---
caseBegin("stale-lock-is-reclaimed", "hooks/workflow-state/state-io/state-lock.js");
check("age: a lock older than STALE_MS (other host) is reclaimed; new payload is ours; released after", () => {
  const lock = freshLock();
  seed(lock, payload({ host: "other.example.invalid", pid: 1 }), L.STALE_MS + 5000);
  const got = L.withStateLockAt(lock, ownPayloadIn(lock), { timeoutMs: SHORT });
  eq([got.pid, got.host, typeof got.at], [process.pid, HOST, "string"], "payload");
  eq(fs.existsSync(lock), false, "lock after release");
});
check("dead-pid: same host, an exited child's pid -> reclaimed", () => {
  const child = spawnSync(process.execPath, ["-e", ""], { encoding: "utf8" });
  const dead = child.pid;
  let code = null;
  try { process.kill(dead, 0); } catch (e) { code = e.code; }
  if (code !== "ESRCH") throw new Error(`fixture: pid ${dead} probe gave ${code}`);
  const lock = freshLock();
  seed(lock, payload({ pid: dead }));
  const got = L.withStateLockAt(lock, ownPayloadIn(lock), { timeoutMs: SHORT });
  eq([got.pid, got.host], [process.pid, HOST], "payload");
});
caseEnd();

// --- 4. fresh mtime, no reclaim ---
caseBegin("fresh-lock-is-kept", "hooks/workflow-state/state-io/state-lock.js");
const keep = [
  ["unparsable payload", "{ not json"], ["empty file", ""], ["array payload", "[1]"], ["null payload", "null"],
  ["string pid", payload({ pid: "123" })], ["non-integer pid", payload({ pid: 1.5 })], ["pid 0", payload({ pid: 0 })],
  ["negative pid", payload({ pid: -1 })], ["other host", payload({ pid: 999999, host: "other.example.invalid" })],
  ["missing host", JSON.stringify({ pid: 999999 })], ["live pid on this host", payload()],
];
for (const [label, text] of keep) {
  check(`no reclaim (fresh, ${label}) -> StateLockTimeoutError, lock unchanged`, () => {
    const lock = freshLock();
    seed(lock, text);
    const before = fs.statSync(lock).mtimeMs;
    const e = expectThrow(() => stub({}, () => L.withStateLockAt(lock, () => 1, { timeoutMs: SHORT })), isTimeout);
    eq(e.unlinked.filter((p) => same(p, lock)), [], "unlinkSync calls on the lock");
    eq([fs.readFileSync(lock, "utf8"), fs.statSync(lock).mtimeMs], [text, before], "lock");
  });
}
caseEnd();

// --- 5. win32 EPERM retry ---
caseBegin("win32-eperm-retry", "hooks/workflow-state/state-io/state-lock.js");
function epermThen(lock, times) {
  let calls = 0;
  return { open: (real, p, flags) => { if (same(p, lock) && ++calls <= times) throw errno("EPERM"); return real(p, flags); }, calls: () => calls };
}
check("win32: EPERM 3 times then success -> acquired", () => {
  const lock = freshLock();
  const ep = epermThen(lock, 3);
  const { result } = stub({ platform: "win32", "fs.openSync": ep.open }, () => L.withStateLockAt(lock, ownPayloadIn(lock), { timeoutMs: 2000 }));
  eq([ep.calls(), result.pid], [4, process.pid], "openSync calls / payload");
});
check("win32: EPERM persisting past the deadline -> the EPERM itself is thrown, not a timeout", () => {
  const lock = freshLock();
  const ep = epermThen(lock, Infinity);
  const e = expectThrow(() => stub({ platform: "win32", "fs.openSync": ep.open }, () => L.withStateLockAt(lock, () => 1, { timeoutMs: SHORT })), (x) => x.code === "EPERM");
  if (isTimeout(e) || ep.calls() < 2) throw new Error(`want retried EPERM, got ${e.name} after ${ep.calls()} calls`);
  eq(fs.existsSync(lock), false, "lock created");
});
check("non-win32: EPERM is thrown at once, no retry", () => {
  const lock = freshLock();
  const ep = epermThen(lock, Infinity);
  expectThrow(() => stub({ platform: "linux", "fs.openSync": ep.open }, () => L.withStateLockAt(lock, () => 1, { timeoutMs: 2000 })), (x) => x.code === "EPERM");
  eq(ep.calls(), 1, "openSync calls");
});
caseEnd();

// --- 6. error paths and boundaries ---
caseBegin("error-paths-and-boundaries", "hooks/workflow-state/state-io/state-lock.js");
check("a non-EEXIST openSync error (EACCES) propagates at once", () => {
  const lock = freshLock();
  let calls = 0;
  expectThrow(() => stub({ "fs.openSync": (real, p, flags) => { if (same(p, lock)) { calls++; throw errno("EACCES"); } return real(p, flags); } },
    () => L.withStateLockAt(lock, () => 1, { timeoutMs: 2000 })), (x) => x.code === "EACCES");
  eq(calls, 1, "openSync calls");
});
check("fn throws -> the error propagates and the lock is released", () => {
  const lock = freshLock();
  expectThrow(() => L.withStateLockAt(lock, () => { throw new Error("boom"); }, { timeoutMs: SHORT }), (x) => x.message === "boom");
  eq(fs.existsSync(lock), false, "lock after throw");
});
check("re-entering withStateLockAt on a held path throws `already held` and keeps the outer lock", () => {
  const lock = freshLock();
  const inner = L.withStateLockAt(lock, () => {
    const e = expectThrow(() => L.withStateLockAt(lock, () => 1, { timeoutMs: SHORT }), (x) => /already held/.test(x.message));
    return [e.message.includes(lock), fs.existsSync(lock)];
  }, { timeoutMs: SHORT });
  eq(inner, [true, true], "inner throw / lock kept");
  eq(fs.existsSync(lock), false, "lock after outer release");
});
check("idempotent: acquire / release twice on the same path both succeed", () => {
  const lock = freshLock();
  eq([L.withStateLockAt(lock, () => "a", { timeoutMs: SHORT }), L.withStateLockAt(lock, () => "b", { timeoutMs: SHORT })], ["a", "b"], "results");
});
check("timeoutMs 0 falls back to the 3000ms default", () => {
  const lock = freshLock();
  seed(lock, payload());
  const t0 = Date.now();
  expectThrow(() => L.withStateLockAt(lock, () => 1, { timeoutMs: 0 }), (x) => isTimeout(x) && /3000ms/.test(x.message));
  const took = Date.now() - t0;
  if (took < 2900) throw new Error(`gave up after ${took}ms`);
});
check("the timeout message names the waited ms and the lock path", () => {
  const lock = freshLock();
  seed(lock, payload());
  const e = expectThrow(() => L.withStateLockAt(lock, () => 1, { timeoutMs: SHORT }), isTimeout);
  eq([e.name, e.message.includes(`${SHORT}ms`), e.message.includes(lock)], ["StateLockTimeoutError", true, true], show(e.message));
});
caseEnd();

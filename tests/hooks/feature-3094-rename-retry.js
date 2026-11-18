#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/rename-retry.js
// Tags: TL1, workflow-state, rename-retry, regression-3094, scope:issue-specific, pwsh-not-required
// #3094: on Windows a state-file rename can fail with a transient EPERM; renameWithRetry retries EPERM
// (win32 only) within RENAME_EPERM_RETRY_MS and rethrows the last original error, and writeStateLocked uses it.
// TL3 gap: a real reader holding the rename target open is not reproduced here; EPERM is injected via a stubbed fs.renameSync.

const { after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restoreEnv = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f3094r-"));
after(() => {
  restoreEnv();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const { check, eq } = require("./feature-2652-state-handoff/check");
const ROOT = path.resolve(__dirname, "..", "..");
const IO = path.join(ROOT, "hooks", "workflow-state", "state-io");
// Loaded lazily so each case fails on its own while the module does not exist yet.
const retry = () => require(path.join(IO, "rename-retry"));
const core = require(path.join(IO, "core"));
const { withStateLock } = require(path.join(IO, "state-lock"));

let n = 0;
function pair(content) {
  const dir = path.join(SCRATCH, `p${++n}`);
  fs.mkdirSync(dir, { recursive: true });
  const from = path.join(dir, "from.tmp");
  const to = path.join(dir, "to.json");
  fs.writeFileSync(from, content);
  fs.writeFileSync(to, "old");
  return { from, to, dir };
}
const errno = (code) => Object.assign(new Error(`${code}: injected`), { code });

// stubRename({ platform, plan }, fn): plan(callNumber) returns an Error to throw or null to run the real rename.
// Returns { result|error, calls, thrown, elapsedMs } and always restores fs.renameSync / process.platform.
function stubRename({ platform, plan }, fn) {
  const realRename = fs.renameSync;
  const platDesc = Object.getOwnPropertyDescriptor(process, "platform");
  const calls = [];
  const thrown = [];
  fs.renameSync = (...args) => {
    calls.push(args);
    const e = plan(calls.length);
    if (e) { thrown.push(e); throw e; }
    return realRename.apply(fs, args);
  };
  Object.defineProperty(process, "platform", { value: platform, configurable: true });
  const t0 = Date.now();
  let error = null;
  let result;
  try {
    result = fn();
  } catch (e) {
    error = e;
  } finally {
    fs.renameSync = realRename;
    Object.defineProperty(process, "platform", platDesc);
  }
  return { result, error, calls: calls.length, thrown, elapsedMs: Date.now() - t0 };
}
const epermFirst = (k) => (i) => (i <= k ? errno("EPERM") : null);
const always = (code) => () => errno(code);
const read = (p) => fs.readFileSync(p, "utf8");

caseBegin("eperm-then-success-is-retried", "hooks/workflow-state/state-io/rename-retry.js");
check("R1 win32: EPERM 3 times then success -> renamed, 4 calls", () => {
  const { from, to } = pair("new");
  const r = stubRename({ platform: "win32", plan: epermFirst(3) }, () => retry().renameWithRetry(from, to));
  if (r.error) throw r.error;
  eq([r.calls, read(to), fs.existsSync(from)], [4, "new", false], "calls / target / source");
});
caseEnd();

caseBegin("persistent-eperm-rethrows-original", "hooks/workflow-state/state-io/rename-retry.js");
check("R2 win32: persistent EPERM -> the last original error object, retried within the budget, source kept", () => {
  const { from, to } = pair("new");
  const budget = retry().RENAME_EPERM_RETRY_MS;
  const r = stubRename({ platform: "win32", plan: always("EPERM") }, () => retry().renameWithRetry(from, to));
  if (!r.error) throw new Error("did not throw");
  eq(r.error.code, "EPERM", "code");
  if (r.error !== r.thrown[r.thrown.length - 1]) throw new Error("not the last original error object (wrapped or replaced)");
  if (r.calls < 2) throw new Error(`not retried: ${r.calls} calls`);
  if (r.elapsedMs < budget * 0.9) throw new Error(`gave up early: ${r.elapsedMs}ms < 0.9*${budget}`);
  if (r.elapsedMs >= 3000) throw new Error(`retried too long: ${r.elapsedMs}ms`);
  eq([read(from), read(to)], ["new", "old"], "source kept / target unchanged");
});
check("R2b the retry budget is 750ms", () => eq(retry().RENAME_EPERM_RETRY_MS, 750, "RENAME_EPERM_RETRY_MS"));
caseEnd();

caseBegin("non-win32-does-not-retry", "hooks/workflow-state/state-io/rename-retry.js");
for (const platform of ["linux", "darwin"]) {
  check(`R3 ${platform}: EPERM is thrown at once, 1 call`, () => {
    const { from, to } = pair("new");
    const r = stubRename({ platform, plan: always("EPERM") }, () => retry().renameWithRetry(from, to));
    if (!r.error) throw new Error("did not throw");
    eq([r.error.code, r.calls, r.error === r.thrown[0]], ["EPERM", 1, true], "code / calls / identity");
  });
}
caseEnd();

caseBegin("other-errno-is-not-retried", "hooks/workflow-state/state-io/rename-retry.js");
for (const code of ["EACCES", "EBUSY"]) {
  check(`R4 win32: ${code} is thrown at once, 1 call`, () => {
    const { from, to } = pair("new");
    const r = stubRename({ platform: "win32", plan: always(code) }, () => retry().renameWithRetry(from, to));
    if (!r.error) throw new Error("did not throw");
    eq([r.error.code, r.calls], [code, 1], "code / calls");
  });
}
caseEnd();

caseBegin("first-try-success-is-one-call", "hooks/workflow-state/state-io/rename-retry.js");
check("R5 win32: success on the first call -> exactly 1 call, no delay", () => {
  const { from, to } = pair("new");
  const r = stubRename({ platform: "win32", plan: () => null }, () => retry().renameWithRetry(from, to));
  if (r.error) throw r.error;
  eq([r.calls, read(to)], [1, "new"], "calls / target");
  if (r.elapsedMs > 500) throw new Error(`slow first-try success: ${r.elapsedMs}ms`);
});
check("R5b non-win32: success on the first call -> exactly 1 call", () => {
  const { from, to } = pair("new");
  const r = stubRename({ platform: "linux", plan: () => null }, () => retry().renameWithRetry(from, to));
  if (r.error) throw r.error;
  eq([r.calls, read(to)], [1, "new"], "calls / target");
});
caseEnd();

caseBegin("other-errno-during-retry-stops-retry", "hooks/workflow-state/state-io/rename-retry.js");
check("R6 win32: EPERM twice then ENOENT -> ENOENT thrown, no further retry (3 calls)", () => {
  const { from, to } = pair("new");
  const plan = (i) => (i <= 2 ? errno("EPERM") : errno("ENOENT"));
  const r = stubRename({ platform: "win32", plan }, () => retry().renameWithRetry(from, to));
  if (!r.error) throw new Error("did not throw");
  eq([r.error.code, r.calls, r.error === r.thrown[2]], ["ENOENT", 3, true], "code / calls / identity");
});
caseEnd();

// writeStateLocked must run with the state lock held (withStateLock).
const sidOf = (k) => `f3094-0000-4000-8000-00000000000${k}`;
const tmpLeft = (statePath) => fs.readdirSync(path.dirname(statePath)).filter((f) => f.endsWith(".tmp"));

caseBegin("write-state-locked-survives-transient-eperm", "hooks/workflow-state/state-io/core.js");
check("W1 win32: writeStateLocked with EPERM twice then success -> state written, no tmp left", () => {
  const sid = sidOf(1);
  const state = core.createInitialState(sid, { cwd: SCRATCH, git_branch: "x" });
  const r = stubRename({ platform: "win32", plan: epermFirst(2) }, () => withStateLock(sid, () => core.writeStateLocked(sid, state)));
  if (r.error) throw r.error;
  const sp = core.getStatePath(sid);
  eq(JSON.parse(read(sp)).session_id, sid, "state file session_id");
  eq([r.calls, tmpLeft(sp)], [3, []], "rename calls / tmp files left");
});
caseEnd();

caseBegin("write-state-locked-keeps-state-on-persistent-eperm", "hooks/workflow-state/state-io/core.js");
check("W2 win32: persistent EPERM -> error propagates after retrying, tmp cleaned, existing state unchanged", () => {
  const sid = sidOf(2);
  const first = core.createInitialState(sid, { cwd: SCRATCH, git_branch: "x" });
  withStateLock(sid, () => core.writeStateLocked(sid, first));
  const sp = core.getStatePath(sid);
  const before = read(sp);
  const next = Object.assign({}, first, { deliverable_type: "wf-other" });
  const r = stubRename({ platform: "win32", plan: always("EPERM") }, () => withStateLock(sid, () => core.writeStateLocked(sid, next)));
  if (!r.error) throw new Error("did not throw");
  eq(r.error.code, "EPERM", "code");
  if (r.calls < 2) throw new Error(`not retried: ${r.calls} calls`);
  eq([read(sp), tmpLeft(sp)], [before, []], "state file / tmp files left");
});
caseEnd();

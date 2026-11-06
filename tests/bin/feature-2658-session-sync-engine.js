"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, jsonl-union, self-heal, process-tree-kill, scope:issue-specific
// #2658: session-sync integrates W (working tree), L (refs/heads/main) and R (origin/main) file by
// file, never through rebase or merge state, so a clone cannot get stuck. Unit cases pin the pure
// rules; two-clone cases drive the real engine CLI against a bare remote under an isolated
// GIT_CONFIG_GLOBAL. The integrate-basic module lives in feature-2658-session-sync-engine-integrate-4.js
// and the integrate-rules module in feature-2658-session-sync-engine-integrate*.js (split to stay under
// the per-file runner timeout). Each module is loaded inside each test, so a missing module fails per case.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const pure = require("./feature-2658-session-sync-engine/pure");
const runtime = require("./feature-2658-session-sync-engine/runtime");
const cli = require("./feature-2658-session-sync-engine/integrate-state");

caseBegin("jsonl-entry-union", "bin/lib/session-sync/jsonl.js");
pure.jsonl(F);
caseEnd();

caseBegin("history-union-time-sort", "bin/lib/session-sync/history.js");
pure.history(F);
caseEnd();

caseBegin("conflict-skew-and-sibling-name", "bin/lib/session-sync/conflict.js");
pure.conflict(F);
caseEnd();

caseBegin("exclude-managed-block", "bin/lib/session-sync/exclude.js");
pure.exclude(F);
caseEnd();

caseBegin("mtime-decision-table", "bin/lib/session-sync/mtime.js");
pure.mtime(F);
caseEnd();

caseBegin("lock-busy-wait-stale", "bin/lib/session-sync/lock.js");
runtime.lock(F);
caseEnd();

caseBegin("proc-deadline-tree-kill", "bin/lib/session-sync/proc.js");
runtime.proc(F);
caseEnd();

caseBegin("git-plan-sync-dependency", "bin/lib/session-sync/git.js");
runtime.gitDep(F);
caseEnd();

caseBegin("cli-exit-codes", "bin/lib/session-sync/cli.js");
cli.exitCodes(F);
caseEnd();

caseBegin("state-results-and-status", "bin/lib/session-sync/state.js");
cli.stateResults(F);
caseEnd();

caseBegin("startup-silent-deadline-busy", "bin/session-sync-engine");
cli.startup(F);
caseEnd();

caseBegin("reset-keeps-local", "bin/lib/session-sync/integrate.js");
cli.reset(F);
caseEnd();

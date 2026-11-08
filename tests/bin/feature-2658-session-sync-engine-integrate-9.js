"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, scope:issue-specific, write-deferred, push-retry, jsonl-union, self-heal, process-tree-kill
// #2658: tenth part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate-5.js
// and feature-2658-session-sync-engine.js so each entrypoint stays under the per-file runner timeout).
// Covers what a rejected or failed push leaves in the reported conflict stats, and the reset case of
// the integrate-state module.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-9-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const retry = require("./feature-2658-session-sync-engine/integrate-retry");
const cli = require("./feature-2658-session-sync-engine/integrate-state");

caseBegin("integrate-push-retry-reports-conflict-once", "bin/lib/session-sync/integrate.js");
retry.reportsOnce(F);
caseEnd();

caseBegin("integrate-failed-push-reports-no-conflict", "bin/lib/session-sync/integrate.js");
retry.failedPush(F);
caseEnd();

caseBegin("reset-keeps-local", "bin/lib/session-sync/integrate.js");
cli.reset(F);
caseEnd();

"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, self-heal, jsonl-union, scope:issue-specific, process-tree-kill
// #2658: fourth part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate.js
// so each entrypoint stays well under the per-file runner timeout). Covers the clone stuck mid-rebase
// self-heal (push, pull and startup background pull) of the integrate-rules module, and the state-results
// case of the integrate-state module (moved here from feature-2658-session-sync-engine.js by runtime). The
// two-clone convergence of a same-uuid jsonl conflict moved to feature-2658-session-sync-engine-integrate-7.js by runtime.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-3-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const rules = require("./feature-2658-session-sync-engine/integrate-rules");
const cli = require("./feature-2658-session-sync-engine/integrate-state");

caseBegin("selfheal-mid-rebase", "bin/lib/session-sync/selfheal.js");
rules.selfheal(F);
caseEnd();

caseBegin("state-results-and-status", "bin/lib/session-sync/state.js");
cli.stateResults(F);
caseEnd();

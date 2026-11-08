"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, self-heal, jsonl-union, scope:issue-specific
// #2658: eighth part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate-2.js
// and -integrate-3.js so each entrypoint stays under the per-file runner timeout). Covers the local
// delete with a remote change of the local-delete module, and the two-clone convergence of a
// same-uuid jsonl conflict.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-7-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const localDelete = require("./feature-2658-session-sync-engine/local-delete");
const conflict = require("./feature-2658-session-sync-engine/jsonl-conflict");

caseBegin("local-delete-with-remote-change", "bin/lib/session-sync/classify.js");
localDelete.remoteChanged(F);
caseEnd();

caseBegin("integrate-same-uuid-conflict-converges", "bin/lib/session-sync/jsonl.js");
conflict.twoClone(F);
caseEnd();

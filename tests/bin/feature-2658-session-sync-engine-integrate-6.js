"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, self-heal, scope:issue-specific
// #2658: seventh part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate-2.js
// so each entrypoint stays under the per-file runner timeout). Covers the two-clone local-delete cases
// of the local-delete module: a local delete the remote keeps, and a deleted path recreated in W;
// plus the in-process unmerged-transcript sibling and history.jsonl concurrent-append cases.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-6-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const localDelete = require("./feature-2658-session-sync-engine/local-delete");

caseBegin("local-delete-kept-in-remote", "bin/lib/session-sync/classify.js");
localDelete.keptInRemote(F);
caseEnd();

caseBegin("local-delete-recreated-in-working-tree", "bin/lib/session-sync/classify.js");
localDelete.recreatedInW(F);
caseEnd();

const unmergedHistory = require("./feature-2658-session-sync-engine/unmerged-history");

caseBegin("unmerged-jsonl-lost-lines-sibling", "bin/lib/session-sync/selfheal.js");
unmergedHistory.unmergedJsonl(F);
caseEnd();

caseBegin("history-local-concurrent-append", "bin/lib/session-sync/integrate.js");
unmergedHistory.historyRace(F);
caseEnd();

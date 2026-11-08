"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, scope:issue-specific, jsonl-union, conflict-sibling
// #2658: ninth part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate-4.js
// so each entrypoint stays under the per-file runner timeout). Covers the two-clone conflict-sibling
// cases: the losing line of a same-uuid conflict survives on both clones, whichever pushes first.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-8-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const sibling = require("./feature-2658-session-sync-engine/conflict-sibling-world");

caseBegin("integrate-losing-line-survives-in-sibling", "bin/lib/session-sync/classify.js");
sibling.losingLineSurvives(F);
caseEnd();

caseBegin("integrate-loser-pushes-first-keeps-losing-line", "bin/lib/session-sync/classify.js");
sibling.loserPushesFirst(F);
caseEnd();

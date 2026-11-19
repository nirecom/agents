"use strict";
// tests/hooks/feature-2941-pm-writer.js
// Tests: hooks/pm-session/writer.js, hooks/pm-session/schema.js, hooks/pm-session/scan.js, hooks/workflow-state/state-io/projection.js
// Tags: TL1, scope:issue-specific, pm-session, user-prompt-submit, workflow-state, forge
// #2941: the hook writer is the only writer of the pm key (init/add/remove/inherit, range overlap
// over the forge, generations), on top of the schema / scan SSOT. Dispatcher only; cases in ./feature-2941-pm-writer/.
// TL3 gap: the writer running inside the live UserPromptSubmit hook process is not observed here.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const neutral = fs.mkdtempSync(path.join(os.tmpdir(), "pm-writer-"));
const savedCwd = process.cwd();
process.chdir(neutral);
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(neutral, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
// On Windows the fake gh's sleeping grandchild (the forge-timeout cases) outlives its killed bash shim and
// keeps `neutral` as its cwd until its 4 s sleep ends. Node 24's rmSync does not wait between retries on
// EPERM, so the removal waits itself, bounded above that sleep.
const RELEASE_WAIT_MS = 10000;
function removeWhenReleased(dir) {
  const until = Date.now() + RELEASE_WAIT_MS;
  for (;;) {
    try { fs.rmSync(dir, { recursive: true, force: true }); return; } catch (e) {
      if (!["EPERM", "EBUSY"].includes(e.code) || Date.now() > until) throw e;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
    }
  }
}
after(() => { process.chdir(savedCwd); removeWhenReleased(neutral); restore(); });

const DIR = path.join(__dirname, "feature-2941-pm-writer");
const initCases = require(path.join(DIR, "init-cases.js"));
const assignCases = require(path.join(DIR, "assign-cases.js"));
const inheritCases = require(path.join(DIR, "inherit-cases.js"));
const scanCases = require(path.join(DIR, "scan-cases.js"));
const homeRefCases = require(path.join(DIR, "home-ref-cases.js"));

caseBegin("pm-key-registered", "hooks/workflow-state/state-io/projection.js");
scanCases.keyCases();
caseEnd();

caseBegin("pm-schema-mark-vs-active", "hooks/pm-session/schema.js");
scanCases.schemaCases();
caseEnd();

caseBegin("pm-scan-tags-owners-generations", "hooks/pm-session/scan.js");
scanCases.scanCases();
caseEnd();

caseBegin("pm-scan-legacy-root", "hooks/pm-session/scan.js");
scanCases.legacyRootCases();
caseEnd();

caseBegin("pm-writer-init-and-wf-init", "hooks/pm-session/writer.js");
initCases.init();
initCases.wfInit();
caseEnd();

caseBegin("pm-writer-add-remove", "hooks/pm-session/writer.js");
assignCases.assign();
caseEnd();

caseBegin("pm-writer-inherit-from", "hooks/pm-session/writer.js");
inheritCases.inherit();
caseEnd();

caseBegin("pm-writer-init-overlap-tag-reason", "hooks/pm-session/writer.js");
initCases.overlap();
initCases.argsAndReason();
caseEnd();

caseBegin("pm-writer-add-overlap-reason", "hooks/pm-session/writer.js");
assignCases.overlapAndReason();
caseEnd();

caseBegin("pm-writer-inherit-sequence-check", "hooks/pm-session/writer.js");
inheritCases.sequenceCases();
caseEnd();

caseBegin("pm-writer-home-repo-normalization", "hooks/pm-session/writer.js");
homeRefCases.homeRefs();
caseEnd();

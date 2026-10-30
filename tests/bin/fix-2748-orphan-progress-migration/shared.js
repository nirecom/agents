"use strict";
// Common setup of the fix-2748-orphan-progress-migration-*.js test files: isolates the workflow dirs
// (before fixture.js reads them), owns the scratch dir and its cleanup, and adds the helpers more
// than one of those files use. Loaded once per test process.

const { isolate } = require("../../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2748-mig-"));
process.on("exit", () => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const M = require("./fixture");
const { PF, check, progressOf, section, settle } = M;
const planLines = (text) => section(text, "## Plan files") || [];
const samePath = (a, b) => path.resolve(String(a)).toLowerCase() === path.resolve(String(b)).toLowerCase();

// writeOrphan(sids, text) — replaces the orphan progress file of sids.downstreamSid and settles the session chain again.
function writeOrphan(sids, text) {
  fs.writeFileSync(progressOf(sids.downstreamSid), text);
  settle([sids.firstSid, sids.downstreamSid]);
}

// finish() — prints the pass/fail total and sets the exit code from it.
function finish() {
  process.stdout.write(`Total: ${M.counts.passed} passed, ${M.counts.failed} failed\n`);
  process.exitCode = M.counts.failed === 0 ? 0 : 1;
}

module.exports = { M, SCRATCH, planLines, samePath, writeOrphan, finish, PF, check };

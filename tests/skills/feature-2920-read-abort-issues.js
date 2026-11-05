#!/usr/bin/env node
"use strict";
// Tests: skills/worktree-end/scripts/read-abort-issues.js
// Tags: TL2, workflow-abort, worktree-end, regression-2920, scope:issue-specific, pwsh-not-required
// #2920: read-abort-issues.js prints the issue numbers an aborted session claimed -- the state's
// closes_issues (bare numbers) united and deduped with the intent's `## Issues` (getClosesIssues
// returns {number, repo?} objects). A bare-number-only reader dropped the objects as NaN; an entry
// naming another repo is not this repository's WIP and must not be printed.
// New file rather than an append: the sibling abort-scripts test is bash and the script is js.
// TL3 gap (what this test does NOT catch):
// - the WE-5 prose that feeds this output to wip-state.sh.

const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2920ri-"));
after(() => {
  restore();
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
});

const X = require("../hooks/feature-2920-workflow-abort/fixture");
const SCRIPT = path.join(X.ROOT, "skills", "worktree-end", "scripts", "read-abort-issues.js");

// seed(sid, stateIssues, intentBody) -- a started session; intentBody null writes no intent.
function seed(sid, stateIssues, intentBody) {
  X.seedPlain(sid);
  const s = X.raw(sid);
  s.closes_issues = stateIssues;
  X.writeRaw(sid, s);
  if (intentBody !== null) fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), intentBody);
}
function printed(sid) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [SCRIPT, sid], { cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `rc=${r.status} stderr=${r.stderr}`);
  return r.stdout.split(/\r?\n/).filter(Boolean);
}

caseBegin("read-abort-issues-intent-issues", "skills/worktree-end/scripts/read-abort-issues.js");
test("intent '## Issues' entries are printed; cross-repo entries are not", () => {
  seed("ri1", [], "# Intent\n\n## Issues\n- #71: first title\n- #72\n- owner/other-repo#73: elsewhere\n- other-repo#74\n\n## Next\n- #75\n");
  assert.deepStrictEqual(printed("ri1"), ["71", "72"]);
});
test("the state / intent union is deduped", () => {
  seed("ri2", [71, 80], "## Issues\n- #71: dup of state\n- #81\n");
  assert.deepStrictEqual(printed("ri2").sort(), ["71", "80", "81"]);
});
test("no intent leaves the state closes_issues alone", () => {
  seed("ri3", [91], null);
  assert.deepStrictEqual(printed("ri3"), ["91"]);
});
caseEnd();

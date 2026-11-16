#!/usr/bin/env node
"use strict";
// Tests: bin/check-plans-dir-isolation/residual-token.js
// Tags: TL2, bin, plans-dir-isolation, residual-token, append-only, classifier-guard, scope:issue-specific
// #2890: the residual retired-variable scan leaves out exactly the shared append-only records
// (docs/changelog/, docs/history/, docs/history.md, root CHANGELOG.md); the retired changelog/
// and look-alike names are scanned. Driven through trackedHits / stagedHits on a fixture repo.
// TL3 gap (what this test does NOT catch):
// - bin/check-plans-dir-isolation.sh run by the real pre-commit hook on this repo.
// Closest-to-action mitigation: the pre-commit hook runs the same module on every commit.
const { caseBegin, caseEnd, gitInit } = require("../lib/harness");

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const RT = require(path.join(ROOT, "bin/check-plans-dir-isolation/residual-token.js"));
// Assembled so this file never carries the literal the scan hunts for.
const TOKEN = "CLAUDE_" + "WORKFLOW_DIR";
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2890-rt-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const EXEMPT = ["docs/changelog/2026.md", "docs/history/2025.md", "docs/history.md", "CHANGELOG.md"];
// No case variant (docs/Changelog/...) here: on a case-insensitive file system it is the same
// file as a record; tests/hooks/feature-2890-append-only-record-path.js pins case sensitivity.
const SCANNED = ["changelog/2026.md", "tests/foo-changelog.md", "sub/CHANGELOG.md", "docs/historyx.md", "docs/changelog-x.md", "src/a.js"];

function git(repo, args) {
  const r = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
}

// A fixture repo whose every listed file holds the token on line 2; `stage` adds without committing.
function fixture(tag, stage) {
  const repo = path.join(TMP, tag);
  fs.mkdirSync(repo);
  gitInit(repo);
  for (const rel of EXEMPT.concat(SCANNED)) {
    const abs = path.join(repo, ...rel.split("/"));
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, `line one\nuses ${TOKEN} here\n`);
  }
  git(repo, ["add", "-A"]);
  if (!stage) git(repo, ["-c", "user.email=f@example.com", "-c", "user.name=f", "commit", "-q", "-m", "fixture"]);
  return repo;
}

const filesOf = (lines) => lines.map((l) => /^RESIDUAL-TOKEN: (.+):\d+$/.exec(l)[1]).sort();

caseBegin("tracked scan skips the four records and flags the rest", "bin/check-plans-dir-isolation/residual-token.js");
test("tracked scan skips the four records and flags the rest", () => {
  const hits = RT.trackedHits(fixture("tracked", false));
  assert.deepEqual(filesOf(hits), [...SCANNED].sort());
  assert.ok(hits.includes("RESIDUAL-TOKEN: changelog/2026.md:2"), JSON.stringify(hits));
});
caseEnd();

caseBegin("staged scan gives the same verdicts as the tracked scan", "bin/check-plans-dir-isolation/residual-token.js");
test("staged scan gives the same verdicts as the tracked scan", () => {
  const repo = fixture("staged", true);
  const hits = RT.stagedHits(repo, RT.stagedPaths(repo));
  assert.deepEqual(filesOf(hits), [...SCANNED].sort());
});
caseEnd();

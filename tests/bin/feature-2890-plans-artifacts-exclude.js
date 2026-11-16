#!/usr/bin/env node
"use strict";
// Tests: bin/check-plans-artifacts
// Tags: TL2, bin, plans-artifacts, append-only, classifier-guard, scope:issue-specific
// #2890: the source scan leaves out exactly the shared append-only records under its scan roots
// (docs/changelog/, docs/history/, docs/history.md); the old "any path containing changelog"
// rule is gone, so the retired changelog/ spelling, case variants and substring hits are scanned.
// TL3 gap (what this test does NOT catch):
// - the pre-commit gate run over the real tree (tests/bin/feature-2434-plans-dir-lint.sh runs it).
// Closest-to-action mitigation: the pre-commit hook runs check-plans-artifacts --source on every commit.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const LINT = require(path.join(ROOT, "bin/check-plans-artifacts"));
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2890-pa-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

// A control-file name assembled under the plans dir: the scan reports it wherever it is scanned.
const VIOLATION = "Write $PLANS_DIR/$SID-detail-plan-terminal.txt now.\n";
const ROOTS = ["skills", "agents", "bin", "hooks", "rules", "docs"];

// A fixture tree holding the violation in `rel` only; returns {rc, out}.
function scan(tag, rel) {
  const tree = path.join(TMP, tag);
  for (const d of ROOTS) fs.mkdirSync(path.join(tree, d), { recursive: true });
  const abs = path.join(tree, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, VIOLATION);
  let out = "";
  const sink = { write: (s) => { out += s; return true; } };
  const rc = LINT.run({ argv: ["--source", tree], cwd: tree, stdout: sink, stderr: { write: () => true } });
  return { rc, out: out.replace(/\\/g, "/") };
}

caseBegin("the records under the scan roots are left out", "bin/check-plans-artifacts");
test("the records under the scan roots are left out", () => {
  for (const [i, rel] of ["docs/changelog/2026.md", "docs/changelog/legacy.md", "docs/history/2025.md", "docs/history.md"].entries()) {
    const { rc, out } = scan(`ex${i}`, rel);
    assert.equal(rc, 0, `${rel}: ${out}`);
  }
});
caseEnd();

caseBegin("look-alikes and the retired spelling are scanned", "bin/check-plans-artifacts");
test("look-alikes and the retired spelling are scanned", () => {
  const scanned = [
    "docs/changelog-x.md", "docs/Changelog/2026.md", "docs/CHANGELOG.md", "bin/foo-changelog.sh",
    "docs/old-changelog/x.md", "docs/changelog.md", "docs/historyx.md", "skills/changelog/SKILL.md",
  ];
  for (const [i, rel] of scanned.entries()) {
    const { rc, out } = scan(`in${i}`, rel);
    assert.equal(rc, 1, `${rel}: ${out}`);
    assert.ok(out.includes(`${rel}:1: `), `${rel} not reported: ${out}`);
  }
});
caseEnd();

caseBegin("a clean tree passes", "bin/check-plans-artifacts");
test("a clean tree passes", () => {
  const tree = path.join(TMP, "clean");
  for (const d of ROOTS) fs.mkdirSync(path.join(tree, d), { recursive: true });
  fs.writeFileSync(path.join(tree, "docs", "changelog-notes.md"), "nothing to see\n");
  const rc = LINT.run({ argv: ["--source", tree], cwd: tree, stdout: { write: () => true }, stderr: { write: () => true } });
  assert.equal(rc, 0);
});
caseEnd();

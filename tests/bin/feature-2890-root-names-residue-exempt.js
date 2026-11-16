#!/usr/bin/env node
"use strict";
// Tests: bin/check-root-names/residue.js
// Tags: TL1, bin, root-names, residue, append-only, classifier-guard, scope:issue-specific
// #2890: the residue scan exempts the shared append-only records and the list's own file, and
// nothing else: the retired changelog/ and look-alike names are scanned for content and path hits.
// TL3 gap (what this test does NOT catch):
// - bin/check-root-names.sh over the real tree (tests/bin/feature-2561-root-names-residue.sh runs it).
// Closest-to-action mitigation: the pre-commit hook runs bin/check-root-names.sh on every commit.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert/strict");
const path = require("node:path");
const { test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const R = require(path.join(ROOT, "bin/check-root-names/residue.js"));

const LIST_REL = "tests/bin/fixture-retired-list.sh";
const LIST = R.parseList(["# retired-names:begin", "# name zorbroot", "# retired-names:end"].join("\n"), LIST_REL);
const EXEMPT = ["docs/changelog/2026.md", "docs/history/2025.md", "docs/history.md", "CHANGELOG.md", LIST_REL];
const SCANNED = ["changelog/2026.md", "tests/foo-changelog.md", "docs/Changelog/2026.md", "sub/CHANGELOG.md", "docs/historyx.md", "src/a.js"];

const flagged = (rels, text) => {
  const out = R.scanFiles(rels.map((rel) => ({ rel, text })), LIST, "residue", null);
  return [...new Set(out.map((l) => l.split(":")[0]))].sort();
};

caseBegin("content hits are skipped only in the records and the list file", "bin/check-root-names/residue.js");
test("content hits are skipped only in the records and the list file", () => {
  assert.deepEqual(flagged(EXEMPT.concat(SCANNED), "keep\nthe zorbroot tree\n"), [...SCANNED].sort());
});
caseEnd();

caseBegin("path hits under a record dir are skipped and elsewhere flagged", "bin/check-root-names/residue.js");
test("path hits under a record dir are skipped and elsewhere flagged", () => {
  const recordPaths = ["docs/changelog/zorbroot.md", "docs/history/zorbroot.md"];
  const otherPaths = ["changelog/zorbroot.md", "docs/zorbroot.md"];
  assert.deepEqual(flagged(recordPaths.concat(otherPaths), null), [...otherPaths].sort());
});
caseEnd();

caseBegin("a clean file is not flagged anywhere", "bin/check-root-names/residue.js");
test("a clean file is not flagged anywhere", () => {
  assert.deepEqual(flagged(EXEMPT.concat(SCANNED), "nothing retired here\n"), []);
});
caseEnd();

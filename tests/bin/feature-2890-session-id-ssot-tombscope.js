#!/usr/bin/env node
"use strict";
// Tests: bin/check-session-id-ssot/scan.js
// Tags: TL2, bin, session-id-ssot, tombstone, append-only, classifier-guard, scope:issue-specific
// #2890: select() keeps the tombstone scan off the shared append-only records, tests/_archive/
// and .git/ only (the retired changelog/ is scanned now); the read scan's wide exclusion is unchanged.
// TL3 gap (what this test does NOT catch):
// - bin/check-session-id-ssot.sh over the real tree (tests/bin/bin-check-session-id-ssot.sh runs it).
// Closest-to-action mitigation: the pre-commit hook runs the guard on every commit.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const S = require(path.join(ROOT, "bin/check-session-id-ssot/scan.js"));
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2890-ssot-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const TOMB_OUT = ["docs/changelog/2026.md", "docs/history/2025.md", "docs/history.md", "CHANGELOG.md", "tests/_archive/old.sh", ".git/config.js"];
const TOMB_IN = ["changelog/2026.md", "docs/Changelog/2026.md", "sub/CHANGELOG.md", "docs/historyx.md", "tests/foo-changelog.md", "src/a.js", "bin/tool.sh", "docs/guide.txt"];
const ALL = TOMB_OUT.concat(TOMB_IN);
for (const rel of ALL) {
  const abs = path.join(TMP, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, "x\n");
}
const NO_TABLES = { allow: [], exempt: [], isolation: [] };

caseBegin("tombstone scope leaves out the records tests archive and git only", "bin/check-session-id-ssot/scan.js");
test("tombstone scope leaves out the records tests archive and git only", () => {
  const { tomb } = S.select(ALL, TMP, NO_TABLES);
  assert.deepEqual(tomb, TOMB_IN);
});
caseEnd();

caseBegin("read scope keeps its wide exclusion", "bin/check-session-id-ssot/scan.js");
test("read scope keeps its wide exclusion", () => {
  const { read } = S.select(ALL, TMP, NO_TABLES);
  // tests/ docs/ changelog/ .git/ and every .md stay out of the read scan, as before #2890.
  assert.deepEqual(read, ["src/a.js", "bin/tool.sh"]);
});
caseEnd();

caseBegin("table exemptions and missing files still apply", "bin/check-session-id-ssot/scan.js");
test("table exemptions and missing files still apply", () => {
  const { tomb, read } = S.select(ALL.concat(["src/missing.js"]), TMP, { allow: ["src/a.js"], exempt: ["changelog/2026.md"], isolation: [] });
  assert.ok(!tomb.includes("changelog/2026.md") && !tomb.includes("src/missing.js"), JSON.stringify(tomb));
  assert.ok(tomb.includes("src/a.js"), JSON.stringify(tomb));
  assert.deepEqual(read, ["bin/tool.sh"]);
});
caseEnd();

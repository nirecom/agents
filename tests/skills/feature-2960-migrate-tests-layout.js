"use strict";
// Tests: skills/migrate-tests/scripts/detect.js
// Tags: TL2, skills, migrate, repo-settings, table-driven, scope:issue-specific
// #2960 — detect(root).uncoveredTests lists the test files the proposed tests section leaves without a
// place: a file directly under tests/ beside category dirs (placement flat), and a suite subfile with
// no entrypoint test file (a file inside the suite dir "x" of a category needs an "x.<ext>" test file
// beside that dir; a non-test x.md does not count). The proposal itself stays as before: a mixed layout proposes its subdir as the category.
// Contract: the #2960 detail plan S7 / S11.
// TL3 gap: a real repository with a mixed or deep tests/ layout; here every layout is a fixture tree.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
after(() => restore());

const CHECKOUT = path.resolve(__dirname, "..", "..");
const DETECT = path.join(CHECKOUT, "skills", "migrate-tests", "scripts", "detect.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "mtl2960-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

function tree(name, files) {
  const d = path.join(TMP, name);
  for (const [rel, body] of Object.entries(files)) {
    const f = path.join(d, ...rel.split("/"));
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, body);
  }
  return d;
}
const byDir = (cats) => [...cats].sort((a, b) => a.dir.localeCompare(b.dir));

// first / categories: the proposed section (top level of the detect result) where a row pins it.
const LAYOUTS = [
  { name: "LY-flat", files: { "tests/a.test.js": "" }, want: [], first: "flat" },
  { name: "LY-by-target", files: { "hooks/h.js": "", "bin/b.sh": "", "tests/hooks/h.test.js": "", "tests/bin/b.sh": "" }, want: [] },
  { name: "LY-by-type", files: { "tests/unit/a.sh": "", "tests/e2e/b.sh": "" }, want: [] },
  { name: "LY-mixed", files: { "tests/a.test.js": "", "tests/hooks/b.test.js": "" }, want: [["tests/a.test.js", "flat"]],
    first: "by-type", categories: [{ dir: "hooks" }] },
  { name: "LY-deep-no-entry", files: { "tests/hooks/x/y.test.js": "" }, want: [["tests/hooks/x/y.test.js", "suite-subfile"]] },
  { name: "LY-deep-with-entry", files: { "tests/hooks/x.sh": "", "tests/hooks/x/y.sh": "" }, want: [] },
  { name: "LY-deep-doc-only", files: { "tests/hooks/x.md": "", "tests/hooks/x/y.sh": "" }, want: [["tests/hooks/x/y.sh", "suite-subfile"]] },
  { name: "LY-deep-near-miss", files: { "tests/hooks/xy.sh": "", "tests/x.sh": "", "tests/hooks/x/y.sh": "" },
    want: [["tests/hooks/x/y.sh", "suite-subfile"], ["tests/x.sh", "flat"]] },
  { name: "LY-runner-support", files: { "tests/run-all.sh": "", "tests/lib/harness.sh": "", "tests/fixtures/f.sh": "", "tests/hooks/a.sh": "" }, want: [] },
  { name: "LY-sorted", files: { "tests/z.sh": "", "tests/bin/q/r.sh": "", "tests/a.sh": "", "tests/bin/p.sh": "" },
    want: [["tests/a.sh", "flat"], ["tests/bin/q/r.sh", "suite-subfile"], ["tests/z.sh", "flat"]] },
];

caseBegin("MTD-uncovered-tests", "skills/migrate-tests/scripts/detect.js");
test("MTD-uncovered-tests: uncoveredTests holds {path, placement} per unplaced test file, sorted by path; [] when none", () => {
  for (const { name, files, want } of LAYOUTS) {
    const root = tree(`layout-${name}`, files);
    const r = require(DETECT).detect(root);
    const expected = want.map(([p, placement]) => ({ path: p, placement }));
    assert.deepEqual(r.uncoveredTests, expected, `${name}: uncoveredTests`);
    assert.deepEqual(require(DETECT).detect(root).uncoveredTests, expected, `${name}: a second detect answers the same`);
  }
});
caseEnd();

caseBegin("MTD-uncovered-tests-section", "skills/migrate-tests/scripts/detect.js");
test("MTD-uncovered-tests-section: a flat layout proposes flat; a mixed layout proposes its subdir as the category, never flat", () => {
  for (const { name, files, first, categories } of LAYOUTS.filter((l) => l.first !== undefined)) {
    const r = require(DETECT).detect(tree(`section-${name}`, files));
    assert.equal(r.candidates[0], first, `${name}: first candidate`);
    if (first === "flat") {
      assert.equal(r.categories, undefined, `${name}: no categories`);
      continue;
    }
    assert.ok(!r.candidates.includes("flat"), `${name}: flat must not be proposed: ${JSON.stringify(r.candidates)}`);
    assert.deepEqual(byDir(r.categories), categories, `${name}: categories`);
    assert.deepEqual(byDir(r.sections["by-target"].categories), categories.map((c) => ({ ...c, covers: [c.dir] })), `${name}: by-target categories`);
  }
});
caseEnd();

caseBegin("MTD-uncovered-tests-empty-tree", "skills/migrate-tests/scripts/detect.js");
test("MTD-uncovered-tests-empty-tree: no tests/ or an empty tests/ still answers uncoveredTests []", () => {
  const none = tree("layout-none", { "src/a.sh": "" });
  const empty = tree("layout-empty", { "src/a.sh": "" });
  fs.mkdirSync(path.join(empty, "tests"));
  for (const [name, root] of [["no tests/", none], ["empty tests/", empty]]) {
    assert.deepEqual(require(DETECT).detect(root).uncoveredTests, [], `${name}: uncoveredTests`);
  }
});
caseEnd();

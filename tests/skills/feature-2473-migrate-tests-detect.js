"use strict";
// Tests: skills/migrate-tests/scripts/detect.js
// Tags: TL2, skills, migrate, repo-settings, scope:issue-specific
// #2473 — /migrate-tests proposes the tests section from what tests/ already holds: files directly
// under tests/ only -> flat; subdirectories -> by-type / by-target candidates; any existing test
// that does not source the test harness -> `testHarness` off and `caseMarker` off. The dotfiles shape
// (flat, .sh mixed with .Tests.ps1, no tests/lib) must come out as flat / off / off.
// Assumed surface (the plan names none): detect(root) -> { categorization | candidates,
// `testHarness`, `caseMarker` }; categorization may be one value or a candidate list.
// TL3 gap: the real dotfiles checkout; here a fixture copies its shape.
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
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "mtd2473-"));
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

const PLAIN_SH = "#!/usr/bin/env bash\nset -u\n[ -f ~/.bashrc ] || echo 'FAIL: no bashrc'\nexit 0\n";
const PESTER = "Describe 'profile' {\n  It 'loads' { $true | Should -Be $true }\n}\n";
const HARNESS_SH = "#!/usr/bin/env bash\n. \"$AGENTS_TEST_HARNESS_DIR/harness.sh\"\npass ok\n";

const DOTFILES = tree("dotfiles", {
  "tests/install-links.sh": PLAIN_SH,
  "tests/git-config.sh": PLAIN_SH,
  "tests/profile.Tests.ps1": PESTER,
});
const BY_DIRS = tree("by-dirs", {
  "tests/unit/a.sh": HARNESS_SH,
  "tests/e2e/b.sh": HARNESS_SH,
});
const ALL_HARNESS = tree("all-harness", {
  "tests/a.sh": HARNESS_SH,
  "tests/b.sh": HARNESS_SH,
});
// The mixed / all-harness pair shares one layout, so only the harness use differs between them.
const MIXED = tree("mixed", {
  "tests/unit/a.sh": HARNESS_SH,
  "tests/unit/b.sh": PLAIN_SH,
  "tests/e2e/c.sh": HARNESS_SH,
});
const ALL_HARNESS_DIRS = tree("all-harness-dirs", {
  "tests/unit/a.sh": HARNESS_SH,
  "tests/unit/b.sh": HARNESS_SH,
  "tests/e2e/c.sh": HARNESS_SH,
});

function detect(root) {
  const mod = require(DETECT);
  const fn = typeof mod === "function" ? mod : mod.detect;
  assert.equal(typeof fn, "function", "detect.js exports detect(root)");
  const r = fn(root);
  const raw = r.candidates !== undefined ? r.candidates : r.categorization;
  return { candidates: Array.isArray(raw) ? raw : [raw], testHarness: r.testHarness, caseMarker: r.caseMarker };
}

caseBegin("MTD-dotfiles-flat-off-off", "skills/migrate-tests/scripts/detect.js");
test("MTD-dotfiles-flat-off-off: flat tests/ mixing .sh and .Tests.ps1 without a harness -> flat, off, off", () => {
  const r = detect(DOTFILES);
  assert.deepEqual(r.candidates, ["flat"], "categorization");
  assert.equal(r.testHarness, "off", "testHarness");
  assert.equal(r.caseMarker, "off", "caseMarker");
});
caseEnd();

caseBegin("MTD-subdirs-by-candidates", "skills/migrate-tests/scripts/detect.js");
test("MTD-subdirs-by-candidates: subdirectories under tests/ -> by-type and by-target candidates, never flat", () => {
  const r = detect(BY_DIRS);
  assert.ok(r.candidates.includes("by-type") && r.candidates.includes("by-target"), `candidates: ${JSON.stringify(r.candidates)}`);
  assert.ok(!r.candidates.includes("flat"), `flat must not be proposed: ${JSON.stringify(r.candidates)}`);
});
caseEnd();

caseBegin("MTD-harness-used-on", "skills/migrate-tests/scripts/detect.js");
test("MTD-harness-used-on: every test sources the harness -> testHarness on, caseMarker on", () => {
  const r = detect(ALL_HARNESS);
  assert.deepEqual(r.candidates, ["flat"], "categorization");
  assert.equal(r.testHarness, "on", "testHarness");
  assert.equal(r.caseMarker, "on", "caseMarker");
});
caseEnd();

caseBegin("MTD-harness-mixed-vs-all", "skills/migrate-tests/scripts/detect.js");
test("MTD-harness-mixed-vs-all: one test without the harness among harness tests -> off/off; the same layout all on the harness -> on/on", () => {
  const cases = [
    { name: "mixed", root: MIXED, want: "off" },
    { name: "all-harness-dirs", root: ALL_HARNESS_DIRS, want: "on" },
  ];
  for (const { name, root, want } of cases) {
    const r = detect(root);
    assert.equal(r.testHarness, want, `${name}: testHarness`);
    assert.equal(r.caseMarker, want, `${name}: caseMarker`);
  }
});
caseEnd();

// Harness spellings that appear only in a comment or a string literal, never as a load line.
const COMMENT_ONLY = tree("comment-only", {
  "tests/a.sh": "#!/usr/bin/env bash\n# TODO: source tests/lib/harness.sh like the agents repo\necho 'see $AGENTS_TEST_HARNESS_DIR/harness.sh'\nexit 0\n",
  "tests/b.js": "// const h = require(\"../lib/harness\");\nconst note = \"require('../lib/harness') is not used here\";\nconsole.log(note);\n",
});

caseBegin("MTD-harness-mention-only-off", "skills/migrate-tests/scripts/detect.js");
test("MTD-harness-mention-only-off: harness named only in comments / string literals -> testHarness off, caseMarker off", () => {
  const r = detect(COMMENT_ONLY);
  assert.equal(r.testHarness, "off", "testHarness");
  assert.equal(r.caseMarker, "off", "caseMarker");
});
caseEnd();

caseBegin("MTD-no-or-empty-tests-dir", "skills/migrate-tests/scripts/detect.js");
test("MTD-no-or-empty-tests-dir: no tests/ dir, or an empty tests/ dir -> flat, off, off", () => {
  const noTests = tree("no-tests", { "src/a.sh": PLAIN_SH });
  const emptyTests = tree("empty-tests", { "src/a.sh": PLAIN_SH });
  fs.mkdirSync(path.join(emptyTests, "tests"));
  for (const [name, root] of [["no tests/", noTests], ["empty tests/", emptyTests]]) {
    const r = detect(root);
    assert.deepEqual(r.candidates, ["flat"], `${name}: categorization`);
    assert.equal(r.testHarness, "off", `${name}: testHarness`);
    assert.equal(r.caseMarker, "off", `${name}: caseMarker`);
  }
});
caseEnd();

const { validateTests } = require(path.join(CHECKOUT, "hooks", "lib", "repo-settings", "validate.js"));
const BY_TARGET = tree("by-target-sections", {
  "hooks/h.js": "",
  "bin/b.sh": "",
  "tests/hooks/h.sh": HARNESS_SH,
  "tests/bin/b.sh": HARNESS_SH,
  "tests/lib/harness.sh": "#!/usr/bin/env bash\n",
  "tests/fixtures/data.txt": "x\n",
});
const BY_TYPE = tree("by-type-sections", {
  "tests/unit/a.sh": PLAIN_SH,
  "tests/e2e/b.sh": PLAIN_SH,
  "tests/lib/helper.sh": "#!/usr/bin/env bash\n",
});
const FLAT = tree("flat-sections", {
  "tests/a.sh": PLAIN_SH,
  "tests/lib/helper.sh": "#!/usr/bin/env bash\n",
});
const byDir = (cats) => [...cats].sort((a, b) => a.dir.localeCompare(b.dir));

caseBegin("MTD-sections-full-and-valid", "skills/migrate-tests/scripts/detect.js");
test("MTD-sections-full-and-valid: sections[<choice>] is the whole tests section and passes validateTests", () => {
  const cases = [
    { name: "by-target", root: BY_TARGET, first: "by-target", supportDirs: ["fixtures", "lib"],
      categories: [{ dir: "bin", covers: ["bin"] }, { dir: "hooks", covers: ["hooks"] }], harness: "on" },
    { name: "by-type", root: BY_TYPE, first: "by-type", supportDirs: ["lib"],
      categories: [{ dir: "e2e" }, { dir: "unit" }], harness: "off" },
    { name: "flat", root: FLAT, first: "flat", supportDirs: ["lib"], categories: undefined, harness: "off" },
  ];
  for (const { name, root, first, supportDirs, categories, harness } of cases) {
    const r = require(DETECT).detect(root);
    assert.equal(r.candidates[0], first, `${name}: first candidate`);
    const s = r.sections[name];
    assert.ok(s, `${name}: sections[${name}] present`);
    assert.equal(s.dir, "tests", `${name}: dir`);
    assert.equal(s.categorization, name, `${name}: categorization`);
    assert.deepEqual(s.supportDirs, supportDirs, `${name}: supportDirs`);
    assert.equal(s.testHarness, harness, `${name}: testHarness`);
    assert.equal(s.caseMarker, harness, `${name}: caseMarker`);
    if (categories === undefined) assert.equal(s.categories, undefined, `${name}: no categories`);
    else assert.deepEqual(byDir(s.categories), categories, `${name}: categories`);
    const v = validateTests(s);
    assert.equal(v.state, "ok", `${name}: validateTests ${JSON.stringify(v.errors)}`);
  }
});
caseEnd();

caseBegin("MTD-sections-every-candidate-valid", "skills/migrate-tests/scripts/detect.js");
test("MTD-sections-every-candidate-valid: each candidate's section validates; by-type never carries covers", () => {
  for (const root of [BY_TARGET, BY_TYPE]) {
    const r = require(DETECT).detect(root);
    assert.deepEqual([...r.candidates].sort(), ["by-target", "by-type"], `${root}: candidates`);
    for (const c of r.candidates) {
      assert.equal(validateTests(r.sections[c]).state, "ok", `${root} ${c}: validateTests`);
    }
    assert.ok(r.sections["by-type"].categories.every((x) => x.covers === undefined), `${root}: by-type covers absent`);
    assert.ok(r.sections["by-target"].categories.every((x) => Array.isArray(x.covers) && x.covers.length > 0), `${root}: by-target covers`);
  }
});
caseEnd();

caseBegin("MTD-sections-without-categories-invalid", "skills/migrate-tests/scripts/detect.js");
test("MTD-sections-without-categories-invalid: a by-* section stripped of categories fails validateTests", () => {
  const r = require(DETECT).detect(BY_TARGET);
  for (const c of ["by-target", "by-type"]) {
    const stripped = { ...r.sections[c] };
    delete stripped.categories;
    const v = validateTests(stripped);
    assert.equal(v.state, "malformed", `${c}: state`);
    assert.ok(v.errors.some((e) => e.startsWith("tests.categories:")), `${c}: errors ${JSON.stringify(v.errors)}`);
  }
});
caseEnd();

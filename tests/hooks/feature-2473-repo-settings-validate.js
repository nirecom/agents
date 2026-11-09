"use strict";
// Tests: hooks/lib/repo-settings.js, .agents.json
// Tags: repo-settings, migrate, test-categorization, scope:issue-specific
// #2473 — the repo settings file reader: section states, schema rules, defaults, the (root, mtime)
// cache, placementOf, and the agents repo's own .agents.json.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
after(() => restore());

const ROOT = path.resolve(__dirname, "..", "..");
const MOD = path.join(ROOT, "hooks", "lib", "repo-settings.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rs2473-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

function rs() {
  return require(MOD);
}

let seq = 0;
function fixture(content) {
  seq += 1;
  const dir = path.join(TMP, `r${seq}`);
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  if (content !== undefined) {
    const text = typeof content === "string" ? content : JSON.stringify(content, null, 2);
    fs.writeFileSync(path.join(dir, ".agents.json"), text);
  }
  return dir;
}

const FLAT = { dir: "tests", categorization: "flat", testHarness: "on", caseMarker: "on" };
const BY_TARGET = {
  dir: "tests",
  categorization: "by-target",
  categories: [
    { dir: "hooks", covers: ["hooks"] },
    { dir: "bin", covers: ["bin"] },
  ],
  supportDirs: ["lib"],
  testHarness: "on",
  caseMarker: "on",
};
const BY_TYPE = { ...BY_TARGET, categorization: "by-type", categories: [{ dir: "unit" }, { dir: "e2e" }] };
const withTests = (tests) => ({ tests });
const kindOf = (p) => (p && typeof p === "object" ? p.kind : p);

// One row per schema verdict: input is the .agents.json content (undefined = no file, a string =
// raw text); want.tests is the tests section state, want.migrate the migrate state when the row pins it.
const VALIDATE_CASES = [
  { name: "normal flat", input: withTests(FLAT), want: { tests: "ok" } },
  { name: "normal by-target", input: withTests(BY_TARGET), want: { tests: "ok" } },
  { name: "normal by-type", input: withTests(BY_TYPE), want: { tests: "ok" } },
  { name: "normal with an unknown top-level section", input: { tests: FLAT, somethingElse: { a: 1 } }, want: { tests: "ok", migrate: "missing" } },
  { name: "missing file", input: undefined, want: { tests: "missing", migrate: "missing" } },
  { name: "missing tests section", input: { migrate: { tracker: "done" } }, want: { tests: "missing", migrate: "ok" } },
  { name: "missing categorization", input: withTests({ ...FLAT, categorization: undefined }), want: { tests: "malformed" } },
  { name: "missing testHarness", input: withTests({ ...FLAT, testHarness: undefined }), want: { tests: "malformed" } },
  { name: "missing caseMarker", input: withTests({ ...FLAT, caseMarker: undefined }), want: { tests: "malformed" } },
  { name: "missing covers on by-target", input: withTests({ ...BY_TARGET, categories: [{ dir: "hooks" }] }), want: { tests: "malformed" } },
  { name: "missing categories on by-type", input: withTests({ ...BY_TYPE, categories: undefined }), want: { tests: "malformed" } },
  { name: "empty file", input: "", want: { tests: "malformed", migrate: "malformed" } },
  { name: "empty tests section", input: withTests({}), want: { tests: "malformed" } },
  { name: "empty categories on by-target", input: withTests({ ...BY_TARGET, categories: [] }), want: { tests: "malformed" } },
  { name: "empty categories on by-type", input: withTests({ ...BY_TYPE, categories: [] }), want: { tests: "malformed" } },
  { name: "single category on by-target", input: withTests({ ...BY_TARGET, categories: [{ dir: "bin", covers: ["bin"] }] }), want: { tests: "ok" } },
  { name: "single category on by-type", input: withTests({ ...BY_TYPE, categories: [{ dir: "unit" }] }), want: { tests: "ok" } },
  { name: "unparsable JSON", input: "{ not json", want: { tests: "malformed", migrate: "malformed" } },
  { name: "unknown key inside tests", input: withTests({ ...FLAT, colour: "red" }), want: { tests: "malformed" } },
  { name: "unknown categorization", input: withTests({ ...FLAT, categorization: "nested" }), want: { tests: "malformed" } },
  { name: "categories on flat", input: withTests({ ...FLAT, categories: [{ dir: "x" }] }), want: { tests: "malformed" } },
  { name: "covers on by-type", input: withTests({ ...BY_TYPE, categories: [{ dir: "unit", covers: ["src"] }] }), want: { tests: "malformed" } },
  { name: "testHarness not on|off", input: withTests({ ...FLAT, testHarness: "yes" }), want: { tests: "malformed" } },
  { name: "caseMarker not a string", input: withTests({ ...FLAT, caseMarker: true }), want: { tests: "malformed" } },
  {
    name: "duplicate category dir",
    input: withTests({ ...BY_TARGET, categories: [{ dir: "bin", covers: ["bin"] }, { dir: "bin", covers: ["x"] }] }),
    want: { tests: "malformed" },
  },
  { name: "duplicate category dir on by-type", input: withTests({ ...BY_TYPE, categories: [{ dir: "unit" }, { dir: "unit" }] }), want: { tests: "malformed" } },
  { name: "duplicate dir in categories and supportDirs", input: withTests({ ...BY_TARGET, supportDirs: ["hooks"] }), want: { tests: "malformed" } },
  { name: "invalid path: nested category dir", input: withTests({ ...BY_TARGET, categories: [{ dir: "a/b", covers: ["a"] }] }), want: { tests: "malformed" } },
];

caseBegin("RS-validate-table", "hooks/lib/repo-settings.js");
test("RS-validate-table: each settings file input gets its tests (and pinned migrate) section state", () => {
  for (const { name, input, want } of VALIDATE_CASES) {
    const got = rs().load(fixture(input));
    assert.equal(got.tests.state, want.tests, `${name}: tests state`);
    if (want.migrate !== undefined) assert.equal(got.migrate.state, want.migrate, `${name}: migrate state`);
  }
});
caseEnd();

caseBegin("RS-many-categories", "hooks/lib/repo-settings.js");
test("RS-many-categories: 10000 categories on by-target and by-type load ok with every one kept in order", () => {
  const dirs = Array.from({ length: 10000 }, (_, i) => `c${String(i).padStart(5, "0")}`);
  const variants = [
    ["by-target", { ...BY_TARGET, categories: dirs.map((dir, i) => ({ dir, covers: [`src${i}`] })) }],
    ["by-type", { ...BY_TYPE, categories: dirs.map((dir) => ({ dir })) }],
  ];
  for (const [label, tests] of variants) {
    const got = rs().load(fixture(withTests(tests)));
    assert.equal(got.tests.state, "ok", `${label}: tests state`);
    assert.deepEqual(got.tests.value.categories.map((c) => c.dir), dirs, `${label}: category dirs`);
  }
});
caseEnd();

caseBegin("RS-defaults", "hooks/lib/repo-settings.js");
test("RS-defaults: dir defaults to tests and supportDirs to []; nothing agents-specific", () => {
  const got = rs().load(fixture(withTests({ categorization: "flat", testHarness: "off", caseMarker: "off" })));
  assert.equal(got.tests.state, "ok");
  assert.equal(got.tests.value.dir, "tests");
  assert.deepEqual(got.tests.value.supportDirs, []);
  assert.equal(got.tests.value.testHarness, "off");
  assert.equal(got.tests.value.caseMarker, "off");
});
caseEnd();

caseBegin("RS-migrate-section", "hooks/lib/repo-settings.js");
test("RS-migrate-section: values are done only; a bad migrate leaves tests intact; migrateDone reads it", () => {
  const bad = rs().load(fixture({ tests: FLAT, migrate: { tracker: "yes" } }));
  assert.equal(bad.migrate.state, "malformed");
  assert.equal(bad.tests.state, "ok");
  const root = fixture({ migrate: { tracker: "done" } });
  const got = rs().load(root);
  assert.equal(got.migrate.state, "ok");
  assert.equal(got.tests.state, "missing");
  assert.equal(rs().migrateDone(root, "tracker"), true);
  assert.equal(rs().migrateDone(root, "issues"), false);
  assert.equal(rs().migrateDone(fixture(), "tracker"), false);
});
caseEnd();

caseBegin("RS-cache", "hooks/lib/repo-settings.js");
test("RS-cache: one object per (root, mtime) across path spellings; a rewrite is re-read", () => {
  const root = fixture(withTests(FLAT));
  const a = rs().load(root);
  const b = rs().load(root.replace(/\\/g, "/"));
  assert.equal(a, b, "same root spelled with / must hit the same cache entry");
  const file = path.join(root, ".agents.json");
  fs.writeFileSync(file, JSON.stringify(withTests({ ...FLAT, testHarness: "off" })));
  const later = new Date(Date.now() + 5000);
  fs.utimesSync(file, later, later);
  const c = rs().load(root);
  assert.notEqual(c, a);
  assert.equal(c.tests.value.testHarness, "off");
});
caseEnd();

caseBegin("RS-placement-by-target", "hooks/lib/repo-settings.js");
test("RS-placement-by-target: category / flat / support / suite-subfile / runner / outside", () => {
  const root = fixture(withTests(BY_TARGET));
  const p = (rel) => kindOf(rs().placementOf(root, rel));
  assert.equal(p("tests/hooks/feature-1-x.js"), "category");
  assert.equal(p("tests/feature-1-x.sh"), "flat");
  assert.equal(p("tests/lib/harness.sh"), "support");
  assert.equal(p("tests/hooks/feature-1-x/case-a.sh"), "suite-subfile");
  assert.equal(p("tests/run-all.sh"), "runner");
  assert.equal(p("bin/foo.sh"), "outside");
});
caseEnd();

caseBegin("RS-placement-flat", "hooks/lib/repo-settings.js");
test("RS-placement-flat: a flat repo with a custom dir places files at its top level", () => {
  const root = fixture(withTests({ ...FLAT, dir: "spec", supportDirs: ["helpers"] }));
  const p = (rel) => kindOf(rs().placementOf(root, rel));
  assert.equal(p("spec/a.Tests.ps1"), "flat");
  assert.equal(p("spec/helpers/common.sh"), "support");
  assert.equal(p("tests/a.sh"), "outside");
});
caseEnd();

caseBegin("RS-version-constants", "hooks/lib/repo-settings.js");
test("RS-version-constants: CURRENT_SETTINGS_VERSION is 1 and MAX_KNOWN_SETTINGS_VERSION equals it", () => {
  assert.equal(rs().CURRENT_SETTINGS_VERSION, 1);
  assert.equal(rs().MAX_KNOWN_SETTINGS_VERSION, rs().CURRENT_SETTINGS_VERSION);
});
caseEnd();

const NEWER = /newer than this release understands \(max known 1\)/;
// One row per schema version verdict, fed to validateDoc directly; want is the state of both sections
// unless want.tests / want.migrate differ.
const VERSION_CASES = [
  { name: "no version is v1", doc: { tests: FLAT }, want: { tests: "ok", migrate: "missing" } },
  { name: "version 1 with tests", doc: { version: 1, tests: FLAT }, want: { tests: "ok", migrate: "missing" } },
  { name: "version 1 alone", doc: { version: 1 }, want: { tests: "missing", migrate: "missing" } },
  { name: "version 2 alone", doc: { version: 2 }, want: { tests: "unsupported", migrate: "unsupported" } },
  { name: "version 2 with valid sections", doc: { version: 2, tests: FLAT, migrate: { tracker: "done" } }, want: { tests: "unsupported", migrate: "unsupported" } },
  { name: "version 99", doc: { version: 99, tests: FLAT }, want: { tests: "unsupported", migrate: "unsupported" } },
  { name: "version string \"1\"", doc: { version: "1", tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
  { name: "version 1.5", doc: { version: 1.5, tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
  { name: "version 0", doc: { version: 0, tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
  { name: "version -1", doc: { version: -1, tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
  { name: "version null", doc: { version: null, tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
  { name: "version true", doc: { version: true, tests: FLAT }, want: { tests: "malformed", migrate: "malformed" } },
];

caseBegin("RS-version-table", "hooks/lib/repo-settings.js");
test("RS-version-table: absent or 1 is v1, a newer integer is unsupported, any other value is malformed", () => {
  for (const { name, doc, want } of VERSION_CASES) {
    const got = rs().validateDoc(doc);
    assert.equal(got.tests.state, want.tests, `${name}: tests state`);
    assert.equal(got.migrate.state, want.migrate, `${name}: migrate state`);
    for (const sec of ["tests", "migrate"]) {
      if (want[sec] === "unsupported") assert.match((got[sec].errors || []).join("\n"), NEWER, `${name}: ${sec} error`);
    }
  }
});
caseEnd();

caseBegin("RS-version-load", "hooks/lib/repo-settings.js");
test("RS-version-load: load(root) on a version 2 file reports both sections unsupported with the newer-version error", () => {
  const got = rs().load(fixture({ version: 2, tests: FLAT, migrate: { tracker: "done" } }));
  assert.equal(got.tests.state, "unsupported");
  assert.equal(got.migrate.state, "unsupported");
  assert.match((got.tests.errors || []).join("\n"), NEWER);
  assert.equal(rs().load(fixture({ version: 1, tests: FLAT })).tests.state, "ok", "version 1 through load");
});
caseEnd();

// #2953 — isMalformedDoc(doc): true when validateDoc reports the tests or migrate section malformed.
// An unsupported (newer) version and an absent section are not malformed.
const MALFORMED_DOC_CASES = [
  { name: "empty object", doc: {}, want: false },
  { name: "version 1 alone", doc: { version: 1 }, want: false },
  { name: "version 1 with valid sections", doc: { version: 1, tests: FLAT, migrate: { tracker: "done" } }, want: false },
  { name: "tests section merely absent", doc: { migrate: { tracker: "done" } }, want: false },
  { name: "version string \"1\"", doc: { version: "1" }, want: true },
  { name: "version 1.5", doc: { version: 1.5 }, want: true },
  { name: "version 0", doc: { version: 0 }, want: true },
  { name: "version -1", doc: { version: -1 }, want: true },
  { name: "version null", doc: { version: null }, want: true },
  { name: "version 2 (unsupported)", doc: { version: 2 }, want: false },
  { name: "version 2 over an invalid tests value (unsupported wins)", doc: { version: 2, tests: "x" }, want: false },
  { name: "tests bogus categorization", doc: { tests: { categorization: "bogus" } }, want: true },
  { name: "tests is an array", doc: { tests: [] }, want: true },
  { name: "migrate invalid value", doc: { migrate: { tracker: "no" } }, want: true },
  { name: "migrate unknown key", doc: { migrate: { x: "done" } }, want: true },
  { name: "non-object array", doc: [], want: true },
  { name: "non-object null", doc: null, want: true },
  { name: "non-object string", doc: "x", want: true },
];

caseBegin("RS-isMalformedDoc-table", "hooks/lib/repo-settings.js");
test("RS-isMalformedDoc-table: true only for a malformed version, tests or migrate section or a non-object doc", () => {
  assert.equal(typeof rs().isMalformedDoc, "function", "isMalformedDoc is exported");
  for (const { name, doc, want } of MALFORMED_DOC_CASES) {
    assert.equal(rs().isMalformedDoc(doc), want, name);
  }
});
caseEnd();

caseBegin("RS-isMalformedDoc-agrees-with-validateDoc", "hooks/lib/repo-settings.js");
test("RS-isMalformedDoc-agrees-with-validateDoc: equals 'a section is malformed' for every version and section row", () => {
  assert.equal(typeof rs().isMalformedDoc, "function", "isMalformedDoc is exported");
  for (const { name, doc } of [...VERSION_CASES, ...MALFORMED_DOC_CASES]) {
    const v = rs().validateDoc(doc);
    assert.equal(rs().isMalformedDoc(doc), v.tests.state === "malformed" || v.migrate.state === "malformed", name);
  }
});
caseEnd();

caseBegin("RS-isMalformedDoc-reexport", "hooks/lib/repo-settings.js");
test("RS-isMalformedDoc-reexport: repo-settings.js re-exports the validate.js function itself", () => {
  const V = require(path.join(ROOT, "hooks", "lib", "repo-settings", "validate.js"));
  assert.equal(typeof V.isMalformedDoc, "function", "validate.js exports isMalformedDoc");
  assert.equal(rs().isMalformedDoc, V.isMalformedDoc);
});
caseEnd();

caseBegin("RS-agents-own", ".agents.json");
test("RS-agents-own: the agents repo carries by-target with 6 categories, _archive/lib support, all migrate done", () => {
  const got = rs().load(ROOT);
  assert.equal(got.tests.state, "ok");
  assert.equal(got.tests.value.categorization, "by-target");
  assert.deepEqual(
    got.tests.value.categories.map((c) => c.dir).sort(),
    ["agents", "bin", "hooks", "install", "skills", "tests"],
  );
  assert.deepEqual([...got.tests.value.supportDirs].sort(), ["_archive", "lib"]);
  assert.equal(got.tests.value.testHarness, "on");
  assert.equal(got.tests.value.caseMarker, "on");
  for (const key of ["tracker", "issues", "tests"]) assert.equal(rs().migrateDone(ROOT, key), true, key);
});
caseEnd();

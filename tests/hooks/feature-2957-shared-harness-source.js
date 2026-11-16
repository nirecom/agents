"use strict";
// Tests: hooks/lib/test-language-registry.json, hooks/lib/test-gates/frontmatter/staged.js, skills/migrate-tests/scripts/detect.js
// Tags: test-gates, repo-settings, harness, migrate, node-precommit, scope:issue-specific
// #2957 — a target repo's JS / PowerShell / Python test may load the agents harness through
// AGENTS_TEST_HARNESS_DIR without a copy: the helperLibrary.sharedSourceRegex of js / pester / pytest
// satisfies MISSING_HARNESS_SOURCE (staged.js) and the harness-load detection of /migrate-tests (detect.js).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const C = require("./feature-2502-language-match-gate/common");

const restore = isolate();
after(() => restore());

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "sh2957-"));
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const NEUTRAL = path.join(ROOT, "neutral");
fs.mkdirSync(NEUTRAL);
const RUNNER = path.join(C.CHECKOUT, "tests", "lib", "precommit-check-runner.js");
const REGISTRY = path.join(C.CHECKOUT, "hooks", "lib", "test-language-registry.json");
const DETECT = path.join(C.CHECKOUT, "skills", "migrate-tests", "scripts", "detect.js");
const { translateEre } = require(path.join(C.CHECKOUT, "hooks", "lib", "ere", "translate.js"));
const H = C.make({ ROOT, NEUTRAL, gitInit });
const SETTINGS = { tests: { categorization: "by-target", categories: [{ dir: "hooks", covers: ["bin"] }], supportDirs: ["lib"], testHarness: "on", caseMarker: "on" } };

const LANG = {
  js: { ext: "js", target: "bin/foo.js", pre: "//", head: ['const { test } = require("node:test");'] },
  pester: { ext: "Tests.ps1", target: "bin/foo.sh", pre: "#", head: [] },
  pytest: { ext: "py", target: "bin/foo.py", pre: "#", head: [] },
};
// body(lang, lines) — a test file with the Tests:/Tags: header every language needs.
function body(lang, lines) {
  const l = LANG[lang];
  return [`${l.pre} Tests: ${l.target}`, `${l.pre} Tags: scope:common`, ...l.head, ...lines, ""].join("\n");
}
let seq = 0;
// run(lang, lines) — stage one new test under tests/hooks and run the frontmatter gate.
function run(lang, lines) {
  const dir = H.mkRepo({ ".agents.json": JSON.stringify(SETTINGS, null, 2) + "\n" }, { noHelpers: true });
  const rel = lang === "pytest" ? `tests/hooks/test_x${++seq}.py` : `tests/hooks/feature-1-x${++seq}.${LANG[lang].ext}`;
  C.writeRel(dir, rel, body(lang, lines));
  C.git(dir, "add", "--", rel);
  const r = spawnSync(process.execPath, [RUNNER, "--cfg", C.CHECKOUT, "tests-frontmatter", "frontmatter"], {
    cwd: dir, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rel, rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}
function pass(lang, lines) {
  const r = run(lang, lines);
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/MISSING_HARNESS_SOURCE|SELF_IMPLEMENTED_HARNESS/.test(r.text), r.text);
}
function fail(lang, lines) {
  const r = run(lang, lines);
  assert.equal(r.rc, 1, r.text);
  assert.ok(r.text.includes(`MISSING_HARNESS_SOURCE: ${r.rel}`), r.text);
  assert.ok(!/MISSING_TESTS_HEADER|MISSING_SCOPE_TAG/.test(r.text), r.text);
}

const JS_PATH = 'const H = require(path.join(process.env.AGENTS_TEST_HARNESS_DIR, "harness"));';
const JS_CONCAT = 'const { caseBegin } = require(process.env.AGENTS_TEST_HARNESS_DIR + "/harness.js");';
const JS_TMPL = "const H = require(`${process.env.AGENTS_TEST_HARNESS_DIR}/harness`);";
const PS_JOIN = ". (Join-Path $env:AGENTS_TEST_HARNESS_DIR 'harness.ps1')";
const PY_INS = 'sys.path.insert(0, os.environ["AGENTS_TEST_HARNESS_DIR"])';

caseBegin("SH-js-pass", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-js-pass: path.join form satisfies the harness source check", () => pass("js", [JS_PATH]));
caseEnd();

caseBegin("SH-js-pass-forms", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-js-pass-forms: concatenation and template forms satisfy the check", () => {
  pass("js", [JS_CONCAT]);
  pass("js", [JS_TMPL]);
});
caseEnd();

caseBegin("SH-pester-pass", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pester-pass: dot-sourcing through AGENTS_TEST_HARNESS_DIR satisfies the check", () => pass("pester", [PS_JOIN]));
caseEnd();

caseBegin("SH-pytest-pass", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pytest-pass: sys.path insertion plus import harness satisfies the check", () => pass("pytest", ["import os, sys", PY_INS, "import harness"]));
caseEnd();

caseBegin("SH-js-no-env", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-js-no-env: a harness require without the env var is MISSING_HARNESS_SOURCE", () => fail("js", ['const H = require("/opt/lib/harness");']));
caseEnd();

caseBegin("SH-js-env-only", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-js-env-only: reading only the env var is MISSING_HARNESS_SOURCE", () => fail("js", ["const d = process.env.AGENTS_TEST_HARNESS_DIR;"]));
caseEnd();

caseBegin("SH-js-other-target", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-js-other-target: loading another module under the env dir is MISSING_HARNESS_SOURCE", () => fail("js", ['const X = require(path.join(process.env.AGENTS_TEST_HARNESS_DIR, "other"));']));
caseEnd();

caseBegin("SH-pester-no-env", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pester-no-env: dot-sourcing without the env var is MISSING_HARNESS_SOURCE", () => fail("pester", [". (Join-Path $PSScriptRoot 'other.ps1')"]));
caseEnd();

caseBegin("SH-pester-env-only", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pester-env-only: reading only the env var is MISSING_HARNESS_SOURCE", () => fail("pester", ["$d = $env:AGENTS_TEST_HARNESS_DIR"]));
caseEnd();

caseBegin("SH-pester-import-module", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pester-import-module: Import-Module of harness.ps1 stays MISSING_HARNESS_SOURCE (D1)", () => fail("pester", ["Import-Module (Join-Path $env:AGENTS_TEST_HARNESS_DIR 'harness.ps1')"]));
caseEnd();

caseBegin("SH-pytest-control", "hooks/lib/test-gates/frontmatter/staged.js");
test("SH-pytest-control: a pytest file with no harness line fires (the fixture is not vacuous)", () => fail("pytest", ["import os", "print('no harness')"]));
caseEnd();

// ---- regex tables (the plan's per-language tables, line -> want) ----
const TABLE = {
  js: [
    [JS_PATH, true], [JS_CONCAT, true], [JS_TMPL, true],
    ['require(path.join(process.env.AGENTS_TEST_HARNESS_DIR, "harness"));', true],
    ['H = require(path.join(process.env.AGENTS_TEST_HARNESS_DIR, "harness"));', false],
    ['const H = await import(path.join(process.env["AGENTS_TEST_HARNESS_DIR"], "harness.js"));', true],
    ["const d = process.env.AGENTS_TEST_HARNESS_DIR;", false],
    ['const H = require("/opt/lib/harness");', false],
    ['const X = require(path.join(process.env.AGENTS_TEST_HARNESS_DIR, "other"));', false],
    ['// const H = require(process.env.AGENTS_TEST_HARNESS_DIR + "/harness");', false],
    ['const d = process.env.AGENTS_TEST_HARNESS_DIR; const H = require(d + "/harness");', false],
  ],
  pester: [
    [PS_JOIN, true], ['. "$env:AGENTS_TEST_HARNESS_DIR/harness.ps1"', true],
    ['    . (Join-Path $env:AGENTS_TEST_HARNESS_DIR "harness.ps1")', true],
    ['. "$env:AGENTS_TEST_HARNESS_DIR\\harness.ps1"', true],
    ["Import-Module (Join-Path $env:AGENTS_TEST_HARNESS_DIR 'harness.ps1')", false],
    ["$d = $env:AGENTS_TEST_HARNESS_DIR", false],
    [". (Join-Path $PSScriptRoot 'other.ps1')", false],
    ["BeforeAll { . (Join-Path $env:AGENTS_TEST_HARNESS_DIR 'harness.ps1') }", false],
  ],
  pytest: [
    [PY_INS, true],
    ['sys.path.append(os.path.join(os.environ["AGENTS_TEST_HARNESS_DIR"], "x"))', true],
    ['sys.path[:0] = [os.environ["AGENTS_TEST_HARNESS_DIR"]]', true],
    ['sys.path += [os.environ["AGENTS_TEST_HARNESS_DIR"]]', true],
    ['d = os.environ["AGENTS_TEST_HARNESS_DIR"]', false],
    ['sys.path.insert(0, "/some/dir")', false],
  ],
};

caseBegin("SH-regex-lines", "hooks/lib/test-language-registry.json");
test("SH-regex-lines: each language's sharedSourceRegex translates and matches its table lines", () => {
  const reg = JSON.parse(fs.readFileSync(REGISTRY, "utf8"));
  for (const [id, rows] of Object.entries(TABLE)) {
    const entry = reg.entries.find((e) => e.id === id);
    const src = entry && entry.helperLibrary && entry.helperLibrary.sharedSourceRegex;
    assert.equal(typeof src, "string", `${id}: sharedSourceRegex missing`);
    const t = translateEre(src);
    assert.equal(t.status, "ok", `${id}: translateEre status ${t.status}`);
    for (const [line, want] of rows) {
      assert.equal(t.regex.test(line), want, `${id}: want=${want} for line: ${line}`);
    }
  }
});
caseEnd();

// ---- detect.js ----
function detectIn(files) {
  const root = fs.mkdtempSync(path.join(ROOT, "det-"));
  for (const [rel, text] of Object.entries(files)) C.writeRel(root, rel, text);
  const r = spawnSync(process.execPath, [DETECT, "--root", root], { encoding: "utf8", timeout: 60000 });
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}
caseBegin("SH-detect", "skills/migrate-tests/scripts/detect.js");
test("SH-detect: a shared harness load keeps testHarness on, a test without one turns it off", () => {
  const shared = {
    js: ["tests/hooks/a.js", JS_PATH + "\n"],
    pester: ["tests/hooks/a.Tests.ps1", PS_JOIN + "\n"],
    pytest: ["tests/hooks/test_a.py", PY_INS + "\n"],
  };
  const plain = { js: "tests/hooks/b.js", pester: "tests/hooks/b.Tests.ps1", pytest: "tests/hooks/test_b.py" };
  for (const [lang, [rel, text]] of Object.entries(shared)) {
    const on = detectIn({ [rel]: text });
    assert.equal(on.testHarness, "on", `${lang} shared: ${JSON.stringify(on)}`);
    assert.equal(on.caseMarker, "on", `${lang} shared caseMarker`);
    const off = detectIn({ [rel]: text, [plain[lang]]: "// nothing to load\n" });
    assert.equal(off.testHarness, "off", `${lang} plain: ${JSON.stringify(off)}`);
    assert.equal(off.caseMarker, "off", `${lang} plain caseMarker`);
  }
});
caseEnd();

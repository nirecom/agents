"use strict";
// Tests: hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js, hooks/lib/test-gates/placement.js, hooks/lib/test-gates/registry.js
// Tags: test-gates, repo-settings, placement, migrate, node-precommit, scope:issue-specific
// #2473 — the frontmatter and case marker gates place tests by the repo settings file (.agents.json)
// of the repo being committed, not by the agents repo's fixed category list: flat, by-type and
// by-target fixtures, the support dirs, the covers mismatch WARN and the uninitialized WARN.
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

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "pg2473-"));
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const NEUTRAL = path.join(ROOT, "neutral");
fs.mkdirSync(NEUTRAL);
const RUNNER = path.join(C.CHECKOUT, "tests", "lib", "precommit-check-runner.js");
const H = C.make({ ROOT, NEUTRAL, gitInit });

const SW = { testHarness: "on", caseMarker: "on" };
const FLAT = { tests: { categorization: "flat", ...SW } };
const BY_TYPE = {
  tests: { categorization: "by-type", categories: [{ dir: "unit" }, { dir: "e2e" }], supportDirs: ["helpers"], ...SW },
};
const BY_TARGET = {
  tests: {
    categorization: "by-target",
    categories: [{ dir: "hooks", covers: ["hooks"] }, { dir: "bin", covers: ["bin"] }],
    supportDirs: ["lib"],
    ...SW,
  },
};

// repo(settings) — a fixture repo with .agents.json committed at HEAD (none when settings is null).
function repo(settings) {
  return H.mkRepo(settings ? { ".agents.json": JSON.stringify(settings, null, 2) + "\n" } : {});
}

// stage(dir, files) — writes and stages {rel: body}.
function stage(dir, files) {
  for (const [rel, body] of Object.entries(files)) {
    C.writeRel(dir, rel, body);
    C.git(dir, "add", "--", rel);
  }
}

function gate(dir, name) {
  const r = spawnSync(process.execPath, [RUNNER, "--cfg", C.CHECKOUT, "tests-frontmatter", name], {
    cwd: dir, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}

const ONE = C.bashBody("scope:common", "bin/foo.sh");
const TWO_NO_MARKERS = C.bashBody("scope:common", "bin/foo.sh, bin/bar.sh");
const NO_HARNESS = "#!/usr/bin/env bash\n# Tests: bin/foo.sh\n# Tags: scope:common\necho hi\n";

caseBegin("PG-flat-top-level", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-flat-top-level: a flat repo accepts a new tests/<file> entrypoint", () => {
  const dir = repo(FLAT);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/FLAT_TEST_/.test(r.text), r.text);
});
caseEnd();

caseBegin("PG-by-type-flat-rejected", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-by-type-flat-rejected: a by-type repo rejects tests/<file> and names its own categories", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /FLAT_TEST_[A-Z_]*REJECTED/);
  assert.match(r.text, /categories: unit e2e/);
  assert.ok(!/categories: [^\n]*\bskills\b/.test(r.text), `agents categories leaked: ${r.text}`);
});
caseEnd();

caseBegin("PG-by-type-entrypoint", "hooks/lib/test-gates/registry.js");
test("PG-by-type-entrypoint: tests/unit/<file> is an entrypoint, so the harness source is required", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/unit/foo.sh": NO_HARNESS });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /MISSING_HARNESS_SOURCE: tests\/unit\/foo\.sh/);
});
caseEnd();

caseBegin("PG-support-dir", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-support-dir: a file under a configured support dir is not checked as a test", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/helpers/common.sh": "#!/usr/bin/env bash\necho helper\n" });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/MISSING_TESTS_HEADER/.test(r.text), r.text);
});
caseEnd();

caseBegin("PG-by-type-case-markers", "hooks/lib/test-gates/placement.js");
test("PG-by-type-case-markers: tests/unit/<file> is a case-marker placement; a support file is not", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/unit/two.sh": TWO_NO_MARKERS });
  const r = H.runPrecommitCaseMarkers(dir);
  const text = `${r.stdout}\n${r.stderr}`;
  assert.equal(r.rc, 1, text);
  assert.match(text, /MISSING_CASE_MARKERS/);
  const dir2 = repo(BY_TYPE);
  stage(dir2, { "tests/helpers/two.sh": TWO_NO_MARKERS });
  const r2 = H.runPrecommitCaseMarkers(dir2);
  assert.equal(r2.rc, 0, `${r2.stdout}\n${r2.stderr}`);
});
caseEnd();

caseBegin("PG-covers-mismatch-warn", "hooks/lib/test-gates/registry.js");
test("PG-covers-mismatch-warn: by-target warns (never blocks) when Tests: is outside the category's covers", () => {
  const dir = repo(BY_TARGET);
  stage(dir, { "tests/hooks/feature-1-x.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.match(r.text, /code=TEST_CATEGORY_MISMATCH/);
  assert.match(r.text, /tests\/hooks\/feature-1-x\.sh/);
  const dir2 = repo(BY_TARGET);
  stage(dir2, { "tests/bin/feature-1-x.sh": ONE });
  const r2 = gate(dir2, "frontmatter");
  assert.equal(r2.rc, 0, r2.text);
  assert.ok(!/TEST_CATEGORY_MISMATCH/.test(r2.text), r2.text);
});
caseEnd();

caseBegin("PG-uninitialized-warn-once", "hooks/lib/test-gates/registry.js");
test("PG-uninitialized-warn-once: no .agents.json → not blocked, one REPO_SETTINGS_UNINITIALIZED WARN", () => {
  const dir = repo(null);
  stage(dir, { "tests/unit/a.sh": ONE, "tests/unit/b.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  const n = (r.text.match(/REPO_SETTINGS_UNINITIALIZED/g) || []).length;
  assert.equal(n, 1, r.text);
});
caseEnd();

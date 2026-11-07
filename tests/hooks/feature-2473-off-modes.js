"use strict";
// Tests: hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js, hooks/block-case-markers.js, hooks/lib/test-gates/frontmatter/staged.js, hooks/lib/test-gates/language-match/judge.js, hooks/lib/test-language-registry.json
// Tags: test-gates, repo-settings, case-markers, harness, migrate, node-precommit, scope:issue-specific
// #2473 — `tests.caseMarker` and `tests.testHarness` of .agents.json decide the case marker gate (Edit
// time and pre-commit), the test harness source / self-implemented test harness checks and judge.js's
// entrypoint test, instead of whether tests/lib/harness.* happens to exist. Uninitialized repos keep
// today's behaviour plus a REPO_SETTINGS_UNINITIALIZED WARN.
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

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "om2473-"));
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const NEUTRAL = path.join(ROOT, "neutral");
fs.mkdirSync(NEUTRAL);
const RUNNER = path.join(C.CHECKOUT, "tests", "lib", "precommit-check-runner.js");
const H = C.make({ ROOT, NEUTRAL, gitInit });

function settings(sw) {
  return {
    tests: {
      categorization: "by-target",
      categories: [{ dir: "hooks", covers: ["hooks"] }, { dir: "bin", covers: ["bin"] }],
      supportDirs: ["lib"],
      testHarness: sw.testHarness,
      caseMarker: sw.caseMarker,
    },
  };
}

// repo(sw, helpers) — sw null: no .agents.json (uninitialized).
function repo(sw, helpers) {
  const head = sw ? { ".agents.json": JSON.stringify(settings(sw), null, 2) + "\n" } : {};
  return H.mkRepo(head, { noHelpers: !helpers });
}

function stage(dir, rel, body) {
  C.writeRel(dir, rel, body);
  C.git(dir, "add", "--", rel);
}

function gate(dir, name) {
  const r = spawnSync(process.execPath, [RUNNER, "--cfg", C.CHECKOUT, "tests-frontmatter", name], {
    cwd: dir, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}

function hookWrite(dir, rel, content) {
  return H.runHook({ tool_name: "Write", cwd: dir, tool_input: { file_path: path.join(dir, ...rel.split("/")), content } });
}

const REL = "tests/hooks/feature-1-two.sh";
const TWO = C.bashBody("scope:common", "bin/foo.sh, bin/bar.sh");
const NO_HARNESS = "#!/usr/bin/env bash\n# Tests: bin/foo.sh\n# Tags: scope:common\necho hi\n";
const SH_BAD = [
  "#!/usr/bin/env bash", "# Tests: bin/foo.sh", "# Tags: scope:common",
  'source "$(dirname "$0")/../../tests/lib/harness.sh"', "PASS=0", "pass() { echo ok; }", "echo done", "",
].join("\n");
const SHARED_SOURCE = [
  "#!/usr/bin/env bash", "# Tests: bin/foo.sh", "# Tags: scope:common",
  'source "$AGENTS_TEST_HARNESS_DIR/harness.sh"', "echo done", "",
].join("\n");

const ON = { testHarness: "on", caseMarker: "on" };
const CM_OFF = { testHarness: "on", caseMarker: "off" };
const TH_OFF = { testHarness: "off", caseMarker: "on" };

// ---- pre-commit case marker gate ----

caseBegin("OM-pc-on-no-helpers", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("OM-pc-on-no-helpers: caseMarker on blocks a markerless new test even with no helper library", () => {
  const dir = repo(ON, false);
  stage(dir, REL, TWO);
  const r = H.runPrecommitCaseMarkers(dir);
  const text = `${r.stdout}\n${r.stderr}`;
  assert.equal(r.rc, 1, text);
  assert.match(text, /MISSING_CASE_MARKERS/);
});
caseEnd();

caseBegin("OM-pc-off", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("OM-pc-off: caseMarker off passes a markerless new test even with the helper library", () => {
  const dir = repo(CM_OFF, true);
  stage(dir, REL, TWO);
  const r = H.runPrecommitCaseMarkers(dir);
  const text = `${r.stdout}\n${r.stderr}`;
  assert.equal(r.rc, 0, text);
  assert.ok(!/MISSING_CASE_MARKERS/.test(text), text);
});
caseEnd();

caseBegin("OM-pc-uninit-helpers", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("OM-pc-uninit-helpers: uninitialized with the helper library keeps today's block", () => {
  const dir = repo(null, true);
  stage(dir, REL, TWO);
  const r = H.runPrecommitCaseMarkers(dir);
  assert.equal(r.rc, 1, `${r.stdout}\n${r.stderr}`);
});
caseEnd();

caseBegin("OM-pc-uninit-no-helpers", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("OM-pc-uninit-no-helpers: uninitialized without helpers passes as today and WARNs once", () => {
  const dir = repo(null, false);
  stage(dir, REL, TWO);
  const r = H.runPrecommitCaseMarkers(dir);
  const text = `${r.stdout}\n${r.stderr}`;
  assert.equal(r.rc, 0, text);
  assert.equal((text.match(/REPO_SETTINGS_UNINITIALIZED/g) || []).length, 1, text);
});
caseEnd();

// ---- Edit-time hook ----

caseBegin("OM-hook-on-no-helpers", "hooks/block-case-markers.js");
test("OM-hook-on-no-helpers: the Edit-time hook blocks with caseMarker on and no helper library", () => {
  const h = hookWrite(repo(ON, false), REL, TWO);
  assert.equal(h.decision, "block", h.raw);
  assert.match(h.reason, /code=MISSING_CASE_MARKERS/);
});
caseEnd();

caseBegin("OM-hook-off", "hooks/block-case-markers.js");
test("OM-hook-off: the Edit-time hook approves with caseMarker off", () => {
  const h = hookWrite(repo(CM_OFF, true), REL, TWO);
  assert.equal(h.decision, "approve", h.raw);
  assert.ok(!/MISSING_CASE_MARKERS/.test(h.reason + h.context), h.raw);
});
caseEnd();

caseBegin("OM-hook-uninit", "hooks/block-case-markers.js");
test("OM-hook-uninit: uninitialized keeps today's verdicts (block with helpers, approve + WARN without)", () => {
  const withHelpers = hookWrite(repo(null, true), REL, TWO);
  assert.equal(withHelpers.decision, "block", withHelpers.raw);
  const without = hookWrite(repo(null, false), REL, TWO);
  assert.equal(without.decision, "approve", without.raw);
  assert.match(without.context, /REPO_SETTINGS_UNINITIALIZED/, without.raw);
});
caseEnd();

// ---- frontmatter gate (staged.js) ----

caseBegin("OM-fm-harness-on-no-helper", "hooks/lib/test-gates/frontmatter/staged.js");
test("OM-fm-harness-on-no-helper: testHarness on requires the harness source even with no helper file", () => {
  const dir = repo(ON, false);
  stage(dir, "tests/hooks/feature-1-x.sh", NO_HARNESS);
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /MISSING_HARNESS_SOURCE: tests\/hooks\/feature-1-x\.sh/);
});
caseEnd();

caseBegin("OM-fm-harness-off", "hooks/lib/test-gates/frontmatter/staged.js");
test("OM-fm-harness-off: testHarness off skips MISSING_HARNESS_SOURCE and SELF_IMPLEMENTED_HARNESS", () => {
  const dir = repo(TH_OFF, true);
  stage(dir, "tests/hooks/feature-1-x.sh", NO_HARNESS);
  stage(dir, "tests/hooks/feature-1-y.sh", SH_BAD);
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/MISSING_HARNESS_SOURCE|SELF_IMPLEMENTED_HARNESS/.test(r.text), r.text);
});
caseEnd();

caseBegin("OM-fm-harness-on-self-impl", "hooks/lib/test-gates/frontmatter/staged.js");
test("OM-fm-harness-on-self-impl: testHarness on still blocks a self-implemented harness (control)", () => {
  const dir = repo(ON, true);
  stage(dir, "tests/hooks/feature-1-y.sh", SH_BAD);
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /SELF_IMPLEMENTED_HARNESS/);
});
caseEnd();

caseBegin("OM-fm-shared-source", "hooks/lib/test-gates/frontmatter/staged.js");
test("OM-fm-shared-source: sourcing the harness through AGENTS_TEST_HARNESS_DIR satisfies testHarness on", () => {
  const dir = repo(ON, false);
  stage(dir, "tests/hooks/feature-1-z.sh", SHARED_SOURCE);
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/MISSING_HARNESS_SOURCE/.test(r.text), r.text);
  // Control in the same setting: without any source line the check does fire.
  const dir2 = repo(ON, false);
  stage(dir2, "tests/hooks/feature-1-z.sh", NO_HARNESS);
  const r2 = gate(dir2, "frontmatter");
  assert.match(r2.text, /MISSING_HARNESS_SOURCE: tests\/hooks\/feature-1-z\.sh/);
});
caseEnd();

caseBegin("OM-fm-uninit-warn", "hooks/lib/test-gates/frontmatter/staged.js");
test("OM-fm-uninit-warn: uninitialized without helpers skips the harness check as today and WARNs", () => {
  const dir = repo(null, false);
  stage(dir, "tests/hooks/feature-1-x.sh", NO_HARNESS);
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.match(r.text, /REPO_SETTINGS_UNINITIALIZED/);
});
caseEnd();

// ---- judge.js isEntrypoint ----

caseBegin("OM-judge-entrypoint", "hooks/lib/test-gates/language-match/judge.js");
test("OM-judge-entrypoint: caseMarker decides the entrypoint; the helper file is not presupposed", () => {
  const J = require(path.join(C.CHECKOUT, "hooks", "lib", "test-gates", "language-match", "judge.js"));
  const R = require(path.join(C.CHECKOUT, "hooks", "lib", "test-gates", "registry.js"));
  const entry = R.match(REL).entry;
  const root = (dir) => dir.replace(/\\/g, "/");
  assert.equal(J.isEntrypoint(REL, entry, root(repo(TH_OFF, false))), true, "caseMarker on, no helper file");
  assert.equal(J.isEntrypoint(REL, entry, root(repo(CM_OFF, true))), false, "caseMarker off");
  assert.equal(J.isEntrypoint(REL, entry, root(repo(null, true))), true, "uninitialized with helper (today)");
  assert.equal(J.isEntrypoint(REL, entry, root(repo(null, false))), false, "uninitialized without helper (today)");
});
caseEnd();

// ---- registry: sharedSourceRegex ----

caseBegin("OM-registry-shared-source-regex", "hooks/lib/test-language-registry.json");
test("OM-registry-shared-source-regex: the bash helperLibrary has a sharedSourceRegex through AGENTS_TEST_HARNESS_DIR", () => {
  const reg = JSON.parse(fs.readFileSync(path.join(C.CHECKOUT, "hooks", "lib", "test-language-registry.json"), "utf8"));
  const bash = reg.entries.find((e) => e.helperLibrary && e.helperLibrary.path === "tests/lib/harness.sh");
  assert.ok(bash, "bash entry with tests/lib/harness.sh");
  const re = bash.helperLibrary.sharedSourceRegex;
  assert.equal(typeof re, "string", JSON.stringify(bash.helperLibrary));
  assert.match(re, /AGENTS_TEST_HARNESS_DIR/);
  for (const e of reg.entries) {
    const s = e.helperLibrary?.sharedSourceRegex;
    if (s !== undefined) assert.ok(typeof s === "string" && s.includes("AGENTS_TEST_HARNESS_DIR"), `${e.id}: ${s}`);
  }
});
caseEnd();

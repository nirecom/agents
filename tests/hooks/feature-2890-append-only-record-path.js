#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/append-only-record-path.js
// Tags: TL2, hooks, glossary, changelog, append-only, path-predicate, classifier-guard, scope:issue-specific
// #2890: the one predicate naming the append-only records (docs/changelog/, docs/history/,
// docs/history.md, root CHANGELOG.md) that the drift check and the four residue checks leave out.
// TL3 gap (what this test does NOT catch):
// - the predicate wired into a real commit gate run by a claude session (consumers have their own tests).
// Closest-to-action mitigation: none needed; the predicate is pure and is loaded as-is by every consumer.
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const REL = "hooks/lib/append-only-record-path.js";
const load = () => require(path.join(ROOT, REL));

caseBegin("the four record paths are true", "hooks/lib/append-only-record-path.js");
test("the four record paths are true", () => {
  const { isAppendOnlyRecordPath: f } = load();
  for (const p of ["docs/changelog/2026.md", "docs/changelog/legacy.md", "docs/history/2025.md", "docs/history/index.md", "docs/history.md", "CHANGELOG.md"]) {
    assert.equal(f(p), true, p);
  }
});
caseEnd();

caseBegin("backslash and leading dot-slash spellings are normalized", "hooks/lib/append-only-record-path.js");
test("backslash and leading dot-slash spellings are normalized", () => {
  const { isAppendOnlyRecordPath: f } = load();
  for (const p of ["docs\\changelog\\2026.md", "docs\\history\\2025.md", "docs\\history.md", "./CHANGELOG.md", "./docs/changelog/2026.md", ".\\docs\\history.md"]) {
    assert.equal(f(p), true, p);
  }
});
caseEnd();

caseBegin("other paths are false", "hooks/lib/append-only-record-path.js");
test("other paths are false", () => {
  const { isAppendOnlyRecordPath: f } = load();
  const no = [
    "changelog/2026.md", "changelog/legacy.md", // the retired location is no longer a record
    "docs/Changelog/2026.md", "docs/History/2025.md", "changelog.md", "Changelog.md", "DOCS/history.md", // case-sensitive
    "docs/changelog-extra/x.md", "docs/historyx.md", "docs/history.md.bak", "docs/historyx/2025.md", // prefix look-alikes
    "sub/CHANGELOG.md", "docs/CHANGELOG.md", "tests/foo-changelog.md", "x/docs/changelog/2026.md", // root only
    "docs/changelog", "docs/history", // the directory itself, without a file below it
    "README.md", "docs/guide.md",
  ];
  for (const p of no) assert.equal(f(p), false, p);
});
caseEnd();

caseBegin("empty non-string and absolute inputs are false", "hooks/lib/append-only-record-path.js");
test("empty non-string and absolute inputs are false", () => {
  const { isAppendOnlyRecordPath: f } = load();
  for (const v of ["", null, undefined, 42, {}, ["CHANGELOG.md"]]) assert.equal(f(v), false, String(v));
  for (const p of ["/CHANGELOG.md", "/docs/changelog/2026.md", "C:/repo/CHANGELOG.md", "C:\\repo\\docs\\history.md"]) {
    assert.equal(f(p), false, p);
  }
});
caseEnd();

caseBegin("the path list is the frozen four", "hooks/lib/append-only-record-path.js");
test("the path list is the frozen four", () => {
  const { APPEND_ONLY_RECORD_PATHS: list } = load();
  assert.ok(Array.isArray(list), "APPEND_ONLY_RECORD_PATHS is an array");
  assert.ok(Object.isFrozen(list), "APPEND_ONLY_RECORD_PATHS is frozen");
  assert.deepEqual([...list].sort(), ["CHANGELOG.md", "docs/changelog/", "docs/history.md", "docs/history/"]);
  assert.throws(() => { "use strict"; list.push("x"); }, TypeError);
});
caseEnd();

caseBegin("the module requires nothing", "hooks/lib/append-only-record-path.js");
test("the module requires nothing", () => {
  const text = fs.readFileSync(path.join(ROOT, REL), "utf8");
  const code = text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  assert.doesNotMatch(code, /\brequire\s*\(/, "a require( call in the predicate module");
  assert.doesNotMatch(code, /^\s*import\s/m, "an import statement in the predicate module");
});
caseEnd();

"use strict";
// Tests: bin/lib/glossary-drift.js, bin/lib/glossary-drift/, hooks/lib/glossary-term.js, bin/check-glossary-drift
// Tags: TL2, bin, glossary, glossary-drift, scope:issue-specific
// #2763 / #2767: the drift matcher splits matching into the identifier context and the prose
// context (rules: docs/architecture/claude-code/glossary-check.md#matching-rules). Dispatch only;
// the parts live in feature-2763-glossary-drift-contexts/, the fixture is feat-2529's.
// TL3 gap: none for the matcher (pure functions over a string); acceptance.js spawns the real
// bin/check-glossary-drift CLI against a fixture repo, so only a live session's commit-time hook
// wiring is not driven here.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { after, test } = require("node:test");

const restore = isolate();
const F = require("./feat-2529-glossary-drift/fixture");
after(() => {
  F.finish();
  restore();
});

caseBegin("identifier-context-table", "bin/lib/glossary-drift.js");
test("identifier-context-table", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/identifier").run(F)));
caseEnd();

caseBegin("declared-identifier-spellings", "bin/lib/glossary-drift.js");
test("declared-identifier-spellings", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/identifier").runDeclared(F)));
caseEnd();

caseBegin("stage-inputs-intent-fields", "bin/lib/glossary-drift.js");
test("stage-inputs-intent-fields", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/stage-inputs").run(F)));
caseEnd();

caseBegin("long-run-linear-time", "bin/lib/glossary-drift.js");
test("long-run-linear-time", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/perf").run(F)));
caseEnd();

caseBegin("identifier-ranges-oracle", "bin/lib/glossary-drift.js");
test("identifier-ranges-oracle", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/perf").runOracle(F)));
caseEnd();

caseBegin("singular-export", "hooks/lib/glossary-term.js");
test("singular-export", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/identifier").runSingular(F)));
caseEnd();

caseBegin("prose-context-table", "bin/lib/glossary-drift.js");
test("prose-context-table", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/prose").run(F)));
caseEnd();

caseBegin("prose-homographs-and-background-words", "bin/lib/glossary-drift.js");
test("prose-homographs-and-background-words", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/prose").runHomographs(F)));
caseEnd();

caseBegin("acceptance-through-the-cli", "bin/check-glossary-drift");
test("acceptance-through-the-cli", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/acceptance").run(F)));
caseEnd();

caseBegin("acceptance-declared-and-long-line", "bin/check-glossary-drift");
test("acceptance-declared-and-long-line", () => noNewFailures(F.failureCount, () => require("./feature-2763-glossary-drift-contexts/acceptance").runDeclared(F)));
caseEnd();

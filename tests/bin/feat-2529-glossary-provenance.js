#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific
// #2529 S1 — glossary provenance: every staged glossary operation (add / delete / redefine per
// category) must match a row of the CONFIRM_INTENT-approved intent glossary or be accepted with
// GLOSSARY_ACCEPTED. Parts live in feat-2529-glossary-provenance/: ops (T3-1), split (T3-2),
// read-failure (T3-3), gate (T3-4), accepted (T3-6), pin (T3-7). T3-5 is feat-2529-glossary-promote.js.
// This entry wires T3-1/T3-2; for the per-file time budget T3-3 runs in -read-failure.js and
// T3-4 in -gate.js, T3-6 in -accepted.js and T3-7 in -pin.js.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feat-2529-glossary-provenance/common");
const ops = require("./feat-2529-glossary-provenance/ops");
const split = require("./feat-2529-glossary-provenance/split");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

caseBegin("t3-1-term-sets-and-definition-normalization", "bin/lib/glossary-provenance.js");
test("t3-1-term-sets-and-definition-normalization", () => noNewFailures(fails, ops.readAndNormalize));
caseEnd();

caseBegin("t3-1-three-operations-by-category", "bin/lib/glossary-provenance.js");
test("t3-1-three-operations-by-category", () => noNewFailures(fails, ops.threeOpsByCategory));
caseEnd();

caseBegin("t3-1-rename-move-and-zero-operation-edits", "bin/lib/glossary-provenance.js");
test("t3-1-rename-move-and-zero-operation-edits", () => noNewFailures(fails, ops.pairsAndNoOps));
caseEnd();

caseBegin("t3-1-case-only-heading-rename-registers", "bin/lib/glossary-provenance.js");
test("t3-1-case-only-heading-rename-registers", () => noNewFailures(fails, ops.caseOnlyRename));
caseEnd();

caseBegin("t3-1-operations-fingerprint", "bin/lib/glossary-provenance.js");
test("t3-1-operations-fingerprint", () => noNewFailures(fails, ops.fingerprints));
caseEnd();

caseBegin("t3-1-definition-matching-and-grants", "bin/lib/glossary-provenance.js");
test("t3-1-definition-matching-and-grants", () => noNewFailures(fails, ops.definitionMatching));
caseEnd();

caseBegin("t3-1-intent-row-checks", "bin/lib/glossary-provenance.js");
test("t3-1-intent-row-checks", () => noNewFailures(fails, ops.intentRowChecks));
caseEnd();

caseBegin("t3-1-case-only-rename-intent-rows", "bin/lib/glossary-provenance.js");
test("t3-1-case-only-rename-intent-rows", () => noNewFailures(fails, ops.caseOnlyRenameRows));
caseEnd();

caseBegin("t3-2-range-split-is-zero-operations", "bin/check-glossary-provenance");
test("t3-2-range-split-is-zero-operations", () => noNewFailures(fails, split.rangeSplit));
caseEnd();

caseBegin("t3-2-legacy-directory-move-is-zero-operations", "bin/check-glossary-provenance");
test("t3-2-legacy-directory-move-is-zero-operations", () => noNewFailures(fails, split.legacyMove));
caseEnd();

#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific
// #2529 S1 — glossary provenance, gate part (T3-4). Split from
// feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feat-2529-glossary-provenance/common");
const gate = require("./feat-2529-glossary-provenance/gate");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

caseBegin("t3-4-checker-forwards-the-session", "hooks/workflow-gate/review-docs-checker.js");
test("t3-4-checker-forwards-the-session", () => noNewFailures(fails, gate.checkerForwardsSession));
caseEnd();

caseBegin("t3-4-invalid-sid-falls-to-b", "hooks/workflow-gate/review-docs-checker.js");
test("t3-4-invalid-sid-falls-to-b", () => noNewFailures(fails, gate.invalidSidFallsToB));
caseEnd();

caseBegin("t3-4-doc-gate-scripts-forward-the-session", "bin/review-doc-gates");
test("t3-4-doc-gate-scripts-forward-the-session", () => noNewFailures(fails, gate.scriptsForwardSession));
caseEnd();

caseBegin("t3-4-session-wiring-in-source", "hooks/workflow-gate/commit-gate-steps.js");
test("t3-4-session-wiring-in-source", () => noNewFailures(fails, gate.staticWiring));
caseEnd();

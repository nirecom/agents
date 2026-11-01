#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific
// #2529 S1 — glossary provenance, pin part (T3-7). Split from
// feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feat-2529-glossary-provenance/common");
const pin = require("./feat-2529-glossary-provenance/pin");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

caseBegin("t3-7-approved-bytes-are-read", "bin/lib/glossary-provenance.js");
test("t3-7-approved-bytes-are-read", () => noNewFailures(fails, pin.approvedBytes));
caseEnd();

caseBegin("t3-7-glossary-change-after-approval", "bin/lib/glossary-provenance.js");
test("t3-7-glossary-change-after-approval", () => noNewFailures(fails, pin.modifiedAfterApproval));
caseEnd();

caseBegin("t3-7-intent-modified-at-the-gate", "bin/check-glossary-provenance");
test("t3-7-intent-modified-at-the-gate", () => noNewFailures(fails, pin.modifiedAtTheGate));
caseEnd();

caseBegin("t3-7-unapproved-intent", "bin/lib/glossary-provenance.js");
test("t3-7-unapproved-intent", () => noNewFailures(fails, pin.unapproved));
caseEnd();

caseBegin("t3-7-one-read-for-sha-and-parse", "bin/lib/glossary-provenance.js");
test("t3-7-one-read-for-sha-and-parse", () => noNewFailures(fails, pin.oneReadForShaAndParse));
caseEnd();

caseBegin("t3-7-artifact-buffer-helpers", "hooks/workflow-state/completion-approval.js");
test("t3-7-artifact-buffer-helpers", () => noNewFailures(fails, pin.artifactBufferHelpers));
caseEnd();

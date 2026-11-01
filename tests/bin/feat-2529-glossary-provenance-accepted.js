#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific
// #2529 S1 — glossary provenance, accepted part (T3-6). Split from
// feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feat-2529-glossary-provenance/common");
const acc = require("./feat-2529-glossary-provenance/accepted");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

caseBegin("t3-6-block-record-and-grant", "hooks/workflow-mark/glossary-accept-handler.js");
test("t3-6-block-record-and-grant", () => noNewFailures(fails, acc.blockRecordAndGrant));
caseEnd();

caseBegin("t3-6-narrow-grants-on-a-move", "hooks/workflow-mark/glossary-accept-handler.js");
test("t3-6-narrow-grants-on-a-move", () => noNewFailures(fails, acc.narrowGrants));
caseEnd();

caseBegin("t3-6-b-grants-follow-the-same-rules", "bin/check-glossary-provenance");
test("t3-6-b-grants-follow-the-same-rules", () => noNewFailures(fails, acc.bGrantSameRules));
caseEnd();

caseBegin("provenance-grant-carried-while-the-blocked-set-is-unchanged", "bin/check-glossary-provenance");
test("provenance-grant-carried-while-the-blocked-set-is-unchanged", () => noNewFailures(fails, acc.carryOnUnchangedBlocked));
caseEnd();

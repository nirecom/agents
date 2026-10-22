#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance, bin/review-doc-glossary, bin/review-doc-gates, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, commit-gate, sentinel, approval, scope:issue-specific
// #2529 S1 — glossary provenance, read-failure part (T3-3). Split from
// feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call; the tests feed the real
// workflow-mark hook its input JSON, and the commit gate is driven through checkReviewDocs.

const { caseBegin, caseEnd } = require("../lib/harness");
const { totals } = require("./feat-2529-glossary-provenance/common");
const rf = require("./feat-2529-glossary-provenance/read-failure");

caseBegin("t3-3-a-intent-missing", "bin/check-glossary-provenance");
rf.caseA();
caseEnd();

caseBegin("t3-3-c-intent-unreadable", "bin/check-glossary-provenance");
rf.caseC();
caseEnd();

caseBegin("t3-3-zero-operations-and-all-scan", "bin/review-doc-glossary");
rf.zeroOpsAndAllScan();
caseEnd();

caseBegin("t3-3-b-session-from-env", "bin/check-glossary-provenance");
rf.caseB();
caseEnd();

caseBegin("t3-3-no-session", "bin/check-glossary-provenance");
rf.noSession();
caseEnd();

caseBegin("t3-3-b-record-write-failure", "bin/check-glossary-provenance");
rf.bWriteFailure();
caseEnd();

caseBegin("t3-3-unreadable-blob-fails-closed", "bin/check-glossary-provenance");
rf.unreadableBlob();
caseEnd();

process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`);
process.exitCode = totals.failed === 0 ? 0 : 1;

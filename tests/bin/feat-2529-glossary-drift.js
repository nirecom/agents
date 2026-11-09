"use strict";
// Tests: bin/check-glossary-drift, bin/lib/glossary-drift.js, hooks/workflow-state/glossary-check/record.js
// Tags: TL2, bin, glossary, glossary-drift, deterministic, scope:issue-specific
// #2529 T5 (S3, the deterministic spelling-drift check): T5-1 variants per stage and the R-S
// staged-blob binding, T5-2 the excluded contexts, T5-3 how a finding is (and is not) resolved.
// Dispatch only; the parts and the shared fixture live in feat-2529-glossary-drift/.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { after, test } = require("node:test");

const restore = isolate();
const F = require("./feat-2529-glossary-drift/fixture");
after(() => {
  F.finish();
  restore();
});

caseBegin("T5-1 variants per stage and the staged blob", "bin/check-glossary-drift");
test("T5-1 variants per stage and the staged blob", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/variants").run(F)));
caseEnd();

caseBegin("T5-2 excluded contexts", "bin/lib/glossary-drift.js");
test("T5-2 excluded contexts", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/exclusions").run(F)));
caseEnd();

caseBegin("T5-3 resolution only by a fix or a same-fingerprint grant", "hooks/workflow-state/glossary-check/record.js");
test("T5-3 resolution only by a fix or a same-fingerprint grant", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/resolution").run(F)));
caseEnd();

caseBegin("grant carried to the new fingerprint on an artifact-only change", "hooks/workflow-state/glossary-check/record.js");
test("grant carried to the new fingerprint on an artifact-only change", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/carry").run(F)));
caseEnd();

caseBegin("grant carried over its role inputs, expired with a shown cause otherwise", "hooks/workflow-state/glossary-check/record.js");
test("grant carried over its role inputs, expired with a shown cause otherwise", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/expiry").run(F)));
caseEnd();

caseBegin("glossary-only change stales a record only through its findings or matching fields", "hooks/workflow-state/glossary-check/record.js");
test("glossary-only change stales a record only through its findings or matching fields", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/fields").run(F)));
caseEnd();

caseBegin("clean record stays current over a glossary-only change", "hooks/workflow-state/glossary-check/record.js");
test("clean record stays current over a glossary-only change", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/fields").cleanRecord(F)));
caseEnd();

caseBegin("glossary-only change with a new variant lapses the grant with cause variants", "hooks/workflow-state/glossary-check/record.js");
test("glossary-only change with a new variant lapses the grant with cause variants", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/fields").variantGrowth(F)));
caseEnd();

caseBegin("definition-only provenance grant survives a later Definition edit", "hooks/workflow-state/glossary-check/record.js");
test("definition-only provenance grant survives a later Definition edit", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/fields").provenanceBasis(F)));
caseEnd();

caseBegin("glossary-only change that removes the finding stales the record and the re-record clears it", "hooks/workflow-state/glossary-check/record.js");
test("glossary-only change that removes the finding stales the record and the re-record clears it", () => noNewFailures(F.failureCount, () => require("./feat-2529-glossary-drift/fields").vanishingFinding(F)));
caseEnd();

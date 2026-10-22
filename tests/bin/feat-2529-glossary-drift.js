"use strict";
// Tests: bin/check-glossary-drift, bin/lib/glossary-drift.js, hooks/workflow-state/glossary-check/record.js
// Tags: TL2, bin, glossary, glossary-drift, deterministic, scope:issue-specific
// #2529 T5 (S3, the deterministic spelling-drift check): T5-1 variants per stage and the R-S
// staged-blob binding, T5-2 the excluded contexts, T5-3 how a finding is (and is not) resolved.
// Dispatch only; the parts and the shared fixture live in feat-2529-glossary-drift/.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("./feat-2529-glossary-drift/fixture");

try {
caseBegin("T5-1 variants per stage and the staged blob", "bin/check-glossary-drift");
require("./feat-2529-glossary-drift/variants").run(F);
caseEnd();

caseBegin("T5-2 excluded contexts", "bin/lib/glossary-drift.js");
require("./feat-2529-glossary-drift/exclusions").run(F);
caseEnd();

caseBegin("T5-3 resolution only by a fix or a same-fingerprint grant", "hooks/workflow-state/glossary-check/record.js");
require("./feat-2529-glossary-drift/resolution").run(F);
caseEnd();
} finally {
  F.finish();
  restore();
}

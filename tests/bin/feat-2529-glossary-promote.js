#!/usr/bin/env node
"use strict";
// Tests: bin/glossary-promote, bin/check-glossary-provenance
// Tags: TL2, bin, glossary, provenance, promote, approval, scope:issue-specific
// #2529 T3-5 — glossary-promote checks before it writes: layer 0 pins the approved intent,
// layer 1 checks the rows against the glossary files, layer 2 checks the applied result.
// Parts live in feat-2529-glossary-promote/: apply, rows (layer 1 + category move), pin (layer 0).

// TL3 gap: the update-docs skill that calls promote is not driven here; promote runs as a CLI
// over fixture repos and fixture sessions whose CONFIRM_INTENT approval is written raw.
// Not expressible black-box: a layer-2 definition-mismatch (promote writes the intent row's
// own definition, so the applied result always matches it); T3-1 covers matchOperations.

const { caseBegin, caseEnd } = require("../lib/harness");
const { totals } = require("./feat-2529-glossary-promote/lib");
const apply = require("./feat-2529-glossary-promote/apply");
const rows = require("./feat-2529-glossary-promote/rows");
const pin = require("./feat-2529-glossary-promote/pin");

caseBegin("t3-5-applies-add-delete-redefine-with-counters", "bin/glossary-promote");
apply.appliesAllOperations();
caseEnd();

caseBegin("t3-5-same-category-add-is-skipped-existing", "bin/glossary-promote");
apply.skippedExisting();
caseEnd();

caseBegin("t3-5-same-category-rewrite-needs-redefine", "bin/glossary-promote");
apply.sameCategoryRewrite();
caseEnd();

caseBegin("t3-5-case-only-rename-pair-applies", "bin/glossary-promote");
apply.caseOnlyRename();
caseEnd();

caseBegin("t3-5-promote-writes-identifier-fields", "bin/glossary-promote");
apply.writesIdentifierFields();
caseEnd();

caseBegin("t3-5-promote-empty-cells-write-no-fields", "bin/glossary-promote");
apply.emptyCellsWriteNoFields();
caseEnd();

caseBegin("t3-5-layer-1-row-blocks", "bin/glossary-promote");
rows.layerOneBlocks();
caseEnd();

caseBegin("t3-5-category-move-pair", "bin/glossary-promote");
rows.categoryMove();
caseEnd();

caseBegin("t3-5-layer-0-approval-pin-and-accepted", "bin/glossary-promote");
pin.unapprovedAndModified();
caseEnd();

caseBegin("t3-5-layer-0-issues-only-edit", "bin/glossary-promote");
pin.issuesOnlyEdit();
caseEnd();

caseBegin("t3-5-intent-basename-is-usage", "bin/glossary-promote");
pin.basenameIsUsage();
caseEnd();

process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`);
process.exitCode = totals.failed === 0 ? 0 : 1;

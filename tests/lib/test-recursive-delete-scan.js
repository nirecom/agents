#!/usr/bin/env node
// Tests: hooks/lib/bash-write-targets/recursive-delete-scan.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// #2210 — unit tests for scanCommandTextForRecursiveDelete(rawCmd). 2-value
// contract (true=block, false=clean); per-segment null folds to true.
// TL3 gap: pwsh rows never run real pwsh.exe.
// Entrypoint only (rules/coding/file-split.md Pattern A) — dispatches to the
// case tables under ./test-recursive-delete-scan/; see that folder's
// harness.js for the shared runner.

"use strict";

require("./test-recursive-delete-scan/cases-core.js");
require("./test-recursive-delete-scan/cases-depth-stress.js");
require("./test-recursive-delete-scan/cases-wrapper.js");
require("./test-recursive-delete-scan/cases-stdin-delivery.js");
require("./test-recursive-delete-scan/cases-language-interpreter.js");
require("./test-recursive-delete-scan/cases-pwsh-pipeline.js");
require("./test-recursive-delete-scan/cases-env-flag.js");

const { getCounts } = require("./test-recursive-delete-scan/harness");
const { passed, failed } = getCounts();

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);

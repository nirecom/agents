#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/lib/run-tests-baseline-evidence/preconditions.js
// Tags: TL2, run-tests, baseline, probe, scope:issue-specific
// precondition-probe.js <sid> <entry-json> — prints JSON of dispatchPrecondition(sid, entry),
// so a preload fault (EACCES on the control dir) reaches the same scan the CLI runs.

const path = require("path");

const ROOT = path.join(__dirname, "..", "..", "..");
const { dispatchPrecondition } = require(path.join(ROOT, "bin", "workflow", "lib", "run-tests-baseline-evidence", "preconditions.js"));

const [sid, entryJson] = process.argv.slice(2);
process.stdout.write(`${JSON.stringify(dispatchPrecondition(sid, JSON.parse(entryJson || "{}")))}\n`);

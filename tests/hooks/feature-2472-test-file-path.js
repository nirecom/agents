#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/test-file-path.js, hooks/workflow-gate/staged-evidence.js, hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/evidence-resolver.js
// Tags: TL2, hooks, write-tests, completion-evidence, test-language-registry, scope:issue-specific
// #2472 T5: write_tests evidence is "a test file or test helper under tests/ or test/", decided
// by one predicate (isTestFilePath) that every caller shares. Parts live in
// feature-2472-test-file-path/.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2472-tfp");
const unit = require("./feature-2472-test-file-path/unit");
const callers = require("./feature-2472-test-file-path/callers");

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

caseBegin("is-test-file-path-predicate-table", "hooks/lib/test-file-path.js");
test("is-test-file-path-predicate-table", () => noNewFailures(fails, unit.predicateTable));
caseEnd();

caseBegin("is-test-file-path-fails-closed-on-unreadable-registry", "hooks/lib/test-file-path.js");
test("is-test-file-path-fails-closed-on-unreadable-registry", () => noNewFailures(fails, unit.registryUnreadableFailsClosed));
caseEnd();

caseBegin("every-write-tests-evidence-caller-agrees", "hooks/workflow-gate/staged-evidence.js");
test("every-write-tests-evidence-caller-agrees", () => noNewFailures(fails, callers.everyCallerAgrees));
caseEnd();

"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Shared harness for the #2210 scanCommandTextForRecursiveDelete unit suite:
// pass/fail tally, the table-driven runTable() runner, and the loadFn()
// require-with-stub loader. No cases live here — every table is in a sibling
// cases-*.js. Split out of the single test-recursive-delete-scan.js when it
// crossed the 500-line hard limit (rules/coding/file-split.md Pattern A),
// mirroring how hooks/lib/bash-write-targets/recursive-delete-scan.js itself
// was split into a directory in round9.

let passed = 0;
let failed = 0;

function pass(label) {
  passed++;
  console.log("PASS: " + label);
}

function fail(label, expected, actual) {
  failed++;
  console.log("FAIL: " + label + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
}

function check(label, actual, expected) {
  if (actual === expected) pass(label);
  else fail(label, expected, actual);
}

// TL3 gap: pure Node unit calls against rawCmd strings only — no real
// bash/pwsh/cmd.exe process expands these payloads (see the dispatcher's
// `# TL3 gap` block for the closest-to-action mitigation).

// Missing module/export degrades to a marker-returning stub so every case still
// runs and fails readably (see tests/lib/test-recursive-delete-flags.js).
function loadFn(modPath, fnName) {
  let mod = null;
  try {
    mod = require(modPath);
  } catch (e) {
    return function () { return "UNAVAILABLE(require " + modPath + ": " + e.message + ")"; };
  }
  const fn = mod && mod[fnName];
  if (typeof fn !== "function") {
    return function () { return "UNAVAILABLE(" + modPath + " exports no " + fnName + ")"; };
  }
  return fn;
}

const scan = loadFn("../../../hooks/lib/bash-write-targets/recursive-delete-scan", "scanCommandTextForRecursiveDelete");

function runTable(title, cases) {
  console.log("");
  console.log("=== " + title + " ===");
  for (const { label, cmd, want } of cases) {
    check(title + ": " + label, scan(cmd), want);
  }
}

function getCounts() {
  return { passed, failed };
}

module.exports = { pass, fail, check, runTable, loadFn, scan, getCounts };

"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Shared tally / runTable() / loadFn() for the sibling cases-*.js tables.

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

// A missing module/export degrades to a marker-returning stub so every case
// still runs and fails readably instead of aborting the whole suite.
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

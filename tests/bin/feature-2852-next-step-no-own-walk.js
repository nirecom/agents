#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/list.js
// Tags: TL1, next-step, current-step, reset-allowance, scope:issue-specific, test-lang-exception:text-only, pwsh-not-required
// #2852: next-step keeps no walk of its own for "the first unsettled step"; every such walk goes
// through firstUnsettledStep of hooks/workflow-state/reconciled-current-step.js. Text-only: the
// shape "a loop over VALID_STEPS whose body tests !isSettledStatus(" must not appear in any
// bin/workflow/lib/next-step/*.js, and the three walk owners require the contract module.
// TL3 gap (what this test does NOT catch):
// - a walk written in another shape (while loop, Array.find over the step list); behavior parity
//   is covered by feature-2852-current-step-contract.js.

const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
after(() => restore());

const ROOT = path.resolve(__dirname, "..", "..");
const LIB = path.join(ROOT, "bin", "workflow", "lib", "next-step");
const OWNERS = ["verdict.js", "advance-shared.js", "list.js"];

// stripComments(src) — drops // and /* */ comments so prose about a walk is not read as one.
const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`\\])\/\/.*$/gm, "$1");

// loopBodies(src) — the body text of every `for (...)` loop whose header names VALID_STEPS.
function loopBodies(src) {
  const out = [];
  const re = /\bfor\s*\(([^)]*)\)\s*\{/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    if (!/VALID_STEPS/.test(m[1])) continue;
    let depth = 1;
    let i = re.lastIndex;
    while (i < src.length && depth > 0) {
      if (src[i] === "{") depth += 1;
      else if (src[i] === "}") depth -= 1;
      i += 1;
    }
    const line = src.slice(0, m.index).split("\n").length;
    out.push({ line, body: src.slice(re.lastIndex, i - 1) });
  }
  return out;
}

function jsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) return jsFiles(p);
    return d.name.endsWith(".js") ? [p] : [];
  });
}

caseBegin("no-own-first-unsettled-walk", "bin/workflow/lib/next-step/verdict.js");
test("the reader finds the VALID_STEPS loops it is meant to inspect", () => {
  // Guard against a reader that silently matches nothing: list.js keeps VALID_STEPS loops that
  // are not walks (row rendering), so at least one loop is seen there.
  const src = stripComments(fs.readFileSync(path.join(LIB, "list.js"), "utf8"));
  assert.ok(loopBodies(src).length >= 1, "no VALID_STEPS loop found in list.js");
});
test("no bin/workflow/lib/next-step/*.js loops over VALID_STEPS testing !isSettledStatus(", () => {
  const hits = [];
  for (const file of jsFiles(LIB)) {
    const src = stripComments(fs.readFileSync(file, "utf8"));
    for (const loop of loopBodies(src)) {
      if (/!\s*isSettledStatus\s*\(/.test(loop.body)) hits.push(`${path.relative(ROOT, file).replace(/\\/g, "/")}:${loop.line}`);
    }
  }
  assert.deepStrictEqual(hits, [], "own first-unsettled walks remain");
});
caseEnd();

function requiresContract(name) {
  const src = stripComments(fs.readFileSync(path.join(LIB, name), "utf8"));
  assert.match(src, /require\(\s*["'][./]*hooks\/workflow-state\/reconciled-current-step(?:\.js)?["']\s*\)/, name);
}

caseBegin("verdict-requires-the-contract", "bin/workflow/lib/next-step/verdict.js");
test("verdict.js requires hooks/workflow-state/reconciled-current-step", () => requiresContract(OWNERS[0]));
caseEnd();

caseBegin("advance-shared-requires-the-contract", "bin/workflow/lib/next-step/advance-shared.js");
test("advance-shared.js requires hooks/workflow-state/reconciled-current-step", () => requiresContract(OWNERS[1]));
caseEnd();

caseBegin("list-requires-the-contract", "bin/workflow/lib/next-step/list.js");
test("list.js requires hooks/workflow-state/reconciled-current-step", () => requiresContract(OWNERS[2]));
caseEnd();

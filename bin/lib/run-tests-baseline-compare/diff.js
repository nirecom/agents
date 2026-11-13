// bin/lib/run-tests-baseline-compare/diff.js — #2956 S4 steps 4-5 and the fingerprint: per case,
// the multiset of base-only lines B_c and branch-only lines R_c, the cut rule, the two shrink
// rules, and the verdict same|new|no-records|branch-missing|base-missing.
"use strict";

const crypto = require("node:crypto");
const { isCut, shrinksOnly } = require("./markers");

const HEAD_MAX = 3;

// normalizeSide(side, normalize, renames) — Map case -> [normalized folded detail...], in order.
function normalizeSide(side, normalize, renames) {
  const byCase = new Map();
  for (const [name, detail] of side.lines) {
    const text = normalize(detail, renames);
    if (!byCase.has(name)) byCase.set(name, []);
    byCase.get(name).push(text);
  }
  return byCase;
}

function fingerprint(side, byCase) {
  const rows = [];
  for (const [name, lines] of byCase) for (const l of lines) rows.push(`${name}\t${l}`);
  rows.sort();
  const body = [`records=${side.recorded ? "cases" : "none"}`, ...rows].join("\n");
  return crypto.createHash("sha256").update(`${body}\n`).digest("hex");
}

// minus(a, b) — the items of a not matched one-for-one in b (cut lines in a always stay when keepCut).
function minus(a, b, keepCut) {
  const left = new Map();
  for (const x of b) left.set(x, (left.get(x) || 0) + 1);
  return a.filter((x) => {
    if (keepCut && isCut(x)) return true;
    const n = left.get(x) || 0;
    if (n === 0) return true;
    left.set(x, n - 1);
    return false;
  });
}

// newLinesOf(baseLines, branchLines) — the branch lines counted as new for one case.
function newLinesOf(baseLines, branchLines) {
  const r = minus(branchLines, baseLines, true);
  if (r.length === 0) return r;
  const b = minus(baseLines, branchLines, false);
  const hasCut = baseLines.some(isCut) || branchLines.some(isCut);
  if (!hasCut && r.length > 0 && r.length === b.length && allShrink(b, r)) return [];
  return r;
}

// allShrink(b, r) — every branch-only line r pairs one-to-one with a base-only line it shrinks.
function allShrink(b, r) {
  const free = [...b];
  return r.every((x) => {
    const i = free.findIndex((y) => shrinksOnly(y, x));
    if (i < 0) return false;
    free.splice(i, 1);
    return true;
  });
}

// compareSides(base, branch, { normalize, renames, end }) — the RESULT fields.
function compareSides(base, branch, { normalize, renames, end }) {
  const baseCases = normalizeSide(base, normalize, []);
  const branchCases = normalizeSide(branch, normalize, renames);
  const fpBase = fingerprint(base, baseCases);
  const fpBranch = fingerprint(branch, branchCases);
  const fresh = [];
  for (const [name, lines] of branchCases) {
    for (const l of newLinesOf(baseCases.get(name) || [], lines)) fresh.push(`${name}\t${l}`);
  }
  const missing = [...base.failCases].some((c) => !branch.seenCases.has(c));
  let verdict;
  if (!base.hasRecords && !branch.hasRecords) verdict = "no-records";
  else if (!branch.hasRecords) verdict = "branch-missing";
  else if (!base.hasRecords) verdict = "base-missing";
  else if (end === "interrupted" && missing) verdict = "branch-missing";
  else verdict = fresh.length ? "new" : "same";
  return { verdict, count: fresh.length, head: fresh.slice(0, HEAD_MAX), all: fresh, fpBase, fpBranch };
}

module.exports = { compareSides, newLinesOf, fingerprint };

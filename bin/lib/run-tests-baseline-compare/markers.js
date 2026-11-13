// bin/lib/run-tests-baseline-compare/markers.js — the #2956 S5 marks and the S4 step-5 rules.
// A count mark `[count=<N>]` and a list mark `[list total=<M>: i1 | i2]` (`\`, `|`, `]` inside an
// item are backslash-escaped); the grammar's contract is test-result-contract.md. A line ending in
// the fold's `\n[cut]` is not comparable (fail-closed).
"use strict";

const { unfold } = require("./normalize");

const CUT_SUFFIX = "\\n[cut]";
const COUNT_RE = /^\[count=(\d+)\]/;
const LIST_RE = /^\[list total=(\d+): /;

const isCut = (line) => line.endsWith(CUT_SUFFIX);

// readList(text, from) — { items, end } of a list body starting at `from`, or null when unterminated.
function readList(text, from) {
  const items = [];
  let cur = "";
  for (let i = from; i < text.length; i += 1) {
    const c = text[i];
    if (c === "\\" && i + 1 < text.length) { cur += text[i + 1]; i += 1; continue; }
    if (c === "|") { items.push(cur.trim()); cur = ""; continue; }
    if (c === "]") {
      if (items.length || cur.trim()) items.push(cur.trim());
      return { items, end: i + 1 };
    }
    cur += c;
  }
  return null;
}

// parseMarks(line) — { template, counts: [N...], lists: [{ total, items }] } of a folded line.
function parseMarks(line) {
  const text = unfold(line);
  const counts = [];
  const lists = [];
  let template = "";
  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);
    const cm = COUNT_RE.exec(rest);
    if (cm) { counts.push(Number(cm[1])); template += "[count=#]"; i += cm[0].length; continue; }
    const lm = LIST_RE.exec(rest);
    const body = lm && readList(text, i + lm[0].length);
    if (body) { lists.push({ total: Number(lm[1]), items: body.items }); template += "[list #]"; i = body.end; continue; }
    template += text[i];
    i += 1;
  }
  return { template, counts, lists };
}

function subMultiset(small, big) {
  const left = new Map();
  for (const x of big) left.set(x, (left.get(x) || 0) + 1);
  for (const x of small) {
    const n = left.get(x) || 0;
    if (n === 0) return false;
    left.set(x, n - 1);
  }
  return true;
}

// shrinksOnly(baseLine, branchLine) — the branch line differs from the base line only by marks
// that went down: each count at most the base's, each list complete on both sides and a
// sub-multiset of the base's. A line pair without any mark never qualifies.
function shrinksOnly(baseLine, branchLine) {
  const b = parseMarks(baseLine);
  const r = parseMarks(branchLine);
  if (b.template !== r.template || r.counts.length + r.lists.length === 0) return false;
  if (r.counts.some((n, k) => n > b.counts[k])) return false;
  return r.lists.every((l, k) => {
    const bl = b.lists[k];
    return l.items.length === l.total && bl.items.length === bl.total && subMultiset(l.items, bl.items);
  });
}

module.exports = { CUT_SUFFIX, isCut, parseMarks, shrinksOnly };

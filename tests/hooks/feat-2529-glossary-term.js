#!/usr/bin/env node
"use strict";
// lang-check: ignore — Japanese fixture strings are test data for Japanese term matching.
// Tests: hooks/lib/glossary-term.js
// Tags: TL1, hooks, glossary, glossary-term, parser, deterministic, scope:issue-specific
// #2529: normalizeTerm, the one term normalization the drift check, grant matching and the
// concern-ledger grant compare. Table-driven: -us / -sis / -ss singulars keep their s, -uses /
// -yses return to them, an acronym plural as written drops its s, non-ASCII text is kept.

const { caseBegin, caseEnd } = require("../lib/harness");
const path = require("node:path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const ROOT = path.resolve(__dirname, "..", "..");
let failures = 0;
function check(name, ok, detail) {
  console.log(ok ? `PASS ${name}` : `FAIL ${name} :: ${detail}`);
  if (!ok) failures += 1;
}
const failureCount = () => failures;
after(() => console.log(failures === 0 ? "ALL PASS" : `${failures} FAILED`));
function load() {
  try {
    return require(path.join(ROOT, "hooks/lib/glossary-term.js")).normalizeTerm;
  } catch (e) {
    check("hooks/lib/glossary-term.js loads", false, e.code || e.message);
    return null;
  }
}

const ROWS = [
  // -us / -sis / -ss singulars and their plurals
  ["status", "status"], ["statuses", "status"], ["Statuses", "status"], ["STATUSES", "status"],
  ["analysis", "analysis"], ["analyses", "analysis"], ["process", "process"], ["processes", "process"],
  ["class", "class"], ["classes", "class"], ["bus", "bus"], ["buses", "bus"],
  ["workflow status", "workflow status"], ["workflow statuses", "workflow status"],
  // acronym plurals as written
  ["GPUs", "gpu"], ["APIs", "api"], ["glossary APIs", "glossary api"], ["GPU-APIs", "gpu api"],
  ["API", "api"], ["apis", "api"],
  // documented limitation: a lowercase -us plural keeps its s
  ["gpus", "gpus"], ["menus", "menus"],
  // the existing rules
  ["policies", "policy"], ["boxes", "box"], ["workflows", "workflow"], ["Workflows", "workflow"],
  ["Glossary-Drifts", "glossary drift"], ["  work   flows ", "work flow"], ["", ""], ["s", "s"],
  // non-ASCII endings: only lowercased
  ["用語チェック", "用語チェック"], ["承認Gates", "承認gates"],
];

caseBegin("normalizeTerm singular and acronym-plural table", "hooks/lib/glossary-term.js");
test("normalizeTerm singular and acronym-plural table", () => noNewFailures(failureCount, () => {
  const normalizeTerm = load();
  if (normalizeTerm) {
    for (const [input, want] of ROWS) {
      const got = normalizeTerm(input);
      check(`normalizeTerm(${JSON.stringify(input)}) -> ${JSON.stringify(want)}`, got === want, JSON.stringify(got));
    }
    // Symmetry: an all-caps word ending in S is singularized like any other word, so the glossary
    // side and the text side meet the same form whatever their case.
    for (const [a, b] of [["AWS", "aws"]]) {
      const [ga, gb] = [normalizeTerm(a), normalizeTerm(b)];
      check(`symmetry: normalizeTerm(${JSON.stringify(a)}) === normalizeTerm(${JSON.stringify(b)})`, ga === gb, `${JSON.stringify(ga)} vs ${JSON.stringify(gb)}`);
    }
  }
}));
caseEnd();

// unsafeTermChars(term) -> the distinct forbidden characters of `term` in first-appearance order
// ([] when safe). Forbidden: $ ` " \ ( ) < > ; | & = and the controls U+0000-U+001F, U+007F.
const FORBIDDEN = ["$", "`", "\"", "\\", "(", ")", "<", ">", ";", "|", "&", "="];
for (let cp = 0; cp <= 0x1f; cp += 1) FORBIDDEN.push(String.fromCharCode(cp));
FORBIDDEN.push("\u007f");
const SAFE_TERMS = ["workflow", "glossary-drift", "AGENTS_MAIN_ROOT", "user's term", "glossary drift", "TL3 gap 2",
  "用語揺れ", "café", "Ünïcode Wörd"];
const unsafeCases = SAFE_TERMS.map((t) => ({ name: `safe ${JSON.stringify(t)}`, input: t, want: [] }))
  .concat(FORBIDDEN.map((ch) => ({ name: `forbidden U+${ch.charCodeAt(0).toString(16).padStart(4, "0")}`, input: `bad${ch}term`, want: [ch] })))
  .concat([{ name: "repeated and mixed forbidden characters", input: "a$(b)$c", want: ["$", "(", ")"] }]);

caseBegin("unsafeTermChars forbidden-character table", "hooks/lib/glossary-term.js");
test("unsafeTermChars forbidden-character table", () => noNewFailures(failureCount, () => {
  let unsafeTermChars = null;
  try {
    unsafeTermChars = require(path.join(ROOT, "hooks/lib/glossary-term.js")).unsafeTermChars;
  } catch (e) {
    check("hooks/lib/glossary-term.js loads for unsafeTermChars", false, e.code || e.message);
  }
  if (typeof unsafeTermChars !== "function") {
    check("unsafeTermChars is exported as a function", false, typeof unsafeTermChars);
  } else {
    for (const c of unsafeCases) {
      let got;
      try { got = unsafeTermChars(c.input); } catch (e) { got = `threw ${e.message}`; }
      check(`unsafeTermChars ${c.name} -> ${JSON.stringify(c.want)}`, JSON.stringify(got) === JSON.stringify(c.want), JSON.stringify(got));
    }
  }
}));
caseEnd();

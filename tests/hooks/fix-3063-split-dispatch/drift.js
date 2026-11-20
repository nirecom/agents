"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, drift, run-all, scope:issue-specific
// T-D3h: tests/run-all.sh's option parser is the source of truth; every `case` label of its
// option prefix loop must be classified in run-parts.js RUN_ALL_OPTIONS. The table may be keyed
// by label or be a list whose entries carry the label / option strings / a RegExp.

const fs = require("fs");
const path = require("path");
const F = require("../../lib/run-tests-outcome-fixture");
const K = require("./kit");
const { check, eq } = F;

// The labels of the first `case "$1" in ... esac` inside the option `while` loop; `*` (the
// first non-option argument) is the parser's stop, not an option, so it is left out.
function parserLabels(text) {
  const lines = text.replace(/\r/g, "").split("\n");
  const start = lines.findIndex((l) => /^\s*case "\$1" in\s*$/.test(l));
  if (start < 0) return null;
  const out = [];
  for (const l of lines.slice(start + 1)) {
    if (/^\s*esac\b/.test(l)) break;
    const m = /^\s*([^\s()]+)\)/.exec(l);
    if (m) for (const label of m[1].split("|")) if (label !== "*") out.push(label);
  }
  return out;
}

// Every string and RegExp reachable in the table, two levels deep.
function tableTerms(table) {
  const strings = new Set();
  const regexps = [];
  const visit = (v, depth) => {
    if (typeof v === "string") strings.add(v);
    else if (v instanceof RegExp) regexps.push(v);
    else if (v && typeof v === "object" && depth < 3) {
      if (!Array.isArray(v)) for (const k of Object.keys(v)) strings.add(k);
      for (const x of Array.isArray(v) ? v : Object.values(v)) visit(x, depth + 1);
    }
  };
  visit(table instanceof Map ? Object.fromEntries(table) : table, 0);
  return { strings, regexps };
}

function classified(label, terms) {
  const sample = label.replace(/\*$/, "x");
  if (terms.strings.has(label)) return true;
  if (label.endsWith("*") && terms.strings.has(label.slice(0, -1))) return true;
  return terms.regexps.some((re) => re.test(sample));
}

const unclassified = (labels, table) => {
  const terms = tableTerms(table);
  return labels.filter((l) => !classified(l, terms));
};

function optionTableCoversRunAllParser() {
  const labels = parserLabels(fs.readFileSync(path.join(F.ROOT, "tests", "run-all.sh"), "utf8"));
  check("T-D3h: the run-all option labels are found", () => {
    eq(Array.isArray(labels) && labels.includes("--all") && labels.includes("-j") && labels.includes("--jobs=*"), true, `labels ${F.show(labels)}`);
  });
  const table = K.runParts().RUN_ALL_OPTIONS;
  check("T-D3h: run-parts.js exports RUN_ALL_OPTIONS", () => (table && typeof table === "object" ? null : `RUN_ALL_OPTIONS=${F.show(table)}`));
  if (!table || typeof table !== "object" || !Array.isArray(labels)) return;
  check("T-D3h: every run-all option label is classified in RUN_ALL_OPTIONS", () => eq(unclassified(labels, table), [], "unclassified labels"));
  check("T-D3h: a parser label missing from the table is reported (mutation)", () => {
    eq(unclassified(labels.concat(["--f3063-new-opt"]), table), ["--f3063-new-opt"], "unclassified labels");
  });
}

module.exports = { optionTableCoversRunAllParser, parserLabels };

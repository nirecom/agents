"use strict";
// The data-line guard of the code-lines fallback (#2992 item 1): bash has no case unit, so a
// split-suite dispatcher that only gains a group string was caught as a case addition.
// addedOnlyData(entry, file, others) -> true when every added code line is a data line (a quoted
// literal inside an array, an array opening or element, a lone `)`), false when any added line is a command or no
// line is added (fail-closed), null for an entry whose case-embed part is not the one this guard
// scans with (the caller keeps its own judgment). The registry part, not the entry id, decides.
// Added = the file's code-line texts whose count exceeds that of every version in others.

const path = require("path");
const R = require("../registry");
const { scan } = require("../parts/bash-case-embed");

const SCANNER = require.resolve("../parts/bash-case-embed");

// True when the entry's caseEmbedRules part is the scanner above (path.relative folds case on win32).
function scansWithThisPart(entry) {
  const p = R.partOf(entry, "caseEmbedRules");
  return p !== null && path.relative(SCANNER, path.join(R.REPO_ROOT, ...p.file.split("/"))) === "";
}

const DQ = '"(?:[^"\\\\$`]|\\\\.|\\$(?!\\())*"';
const SQ = "'[^']*'";
const ARRAY_OPEN = /^[A-Za-z_][A-Za-z0-9_]*\+?=\($/;
const ELEMENTS = new RegExp(`^(?:${DQ}|${SQ}|[A-Za-z0-9_./:+-]+)(?:[ \\t]+(?:${DQ}|${SQ}|[A-Za-z0-9_./:+-]+))*$`);

const codeOf = (file) => scan(file, []).code.slice(1).map((l) => l.trim());

// classify(lines) -> per line: "" (no code), "data", or "command"; tracks being inside an array.
function classify(lines) {
  let inArray = false;
  return lines.map((t) => {
    if (!t) return "";
    if (t === ")") {
      inArray = false;
      return "data";
    }
    if (inArray) {
      if (ELEMENTS.test(t)) return "data";
      inArray = false;
      return "command";
    }
    if (ARRAY_OPEN.test(t)) {
      inArray = true;
      return "data";
    }
    return "command"; // outside an array a quoted word starts a command line ("$NODE" \), never data
  });
}

function counts(lines) {
  const m = new Map();
  for (const t of lines) if (t) m.set(t, (m.get(t) || 0) + 1);
  return m;
}

function addedOnlyData(entry, file, others) {
  if (!scansWithThisPart(entry)) return null;
  try {
    const lines = codeOf(file);
    const kinds = classify(lines);
    const before = others.map((o) => counts(codeOf(o)));
    const added = new Set();
    for (const [t, n] of counts(lines)) if (before.every((b) => n > (b.get(t) || 0))) added.add(t);
    if (added.size === 0) return false;
    return lines.every((t, i) => !added.has(t) || kinds[i] === "data");
  } catch {
    return false;
  }
}

module.exports = { addedOnlyData };

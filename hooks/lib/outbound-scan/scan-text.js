"use strict";
// Outbound scan of text in the D5 result shape. Lines split as bash `read -r` reads them: on \n
// only, \r kept, a last line without newline scanned, NUL bytes dropped.
// scanText(text, {file, lists}) -> { verdict, messages, details: { findings, incomplete } }

const { compileScanner } = require("./scan-line");
const F = require("./format");

// The pattern source is required per call, so a re-required (or stubbed) SSOT is what runs.
function hardSecrets() {
  const { HARD_SECRET_PATTERNS } = require("./hard-secret-patterns");
  if (!Array.isArray(HARD_SECRET_PATTERNS) || HARD_SECRET_PATTERNS.length === 0) {
    return { error: "no hard-secret patterns loaded" };
  }
  const ok = (v) => typeof v === "string" && v !== "" && !v.includes(" ");
  if (!HARD_SECRET_PATTERNS.every((h) => h && ok(h.label) && ok(h.group) && typeof h.ere === "string" && h.ere !== "")) {
    return { error: "malformed hard-secret pattern entry" };
  }
  return { patterns: HARD_SECRET_PATTERNS };
}

// prepareScan(lists) -> { scanLine } | { incomplete: {reason} }
function prepareScan(lists) {
  const hs = hardSecrets();
  if (hs.error) return { incomplete: { reason: hs.error } };
  return compileScanner(lists, hs.patterns);
}

function splitLines(text) {
  const rows = String(text).split("\0").join("").split("\n");
  if (rows[rows.length - 1] === "") rows.pop();
  return rows;
}

function scanLines(scanner, text, file) {
  const findings = [];
  splitLines(text).forEach((line, i) => findings.push(...scanner.scanLine(file, i + 1, line)));
  return findings;
}

// resultOf(findings, incomplete) -> the D5 result of one scanned file.
function resultOf(findings, incomplete) {
  if (incomplete) {
    return { verdict: "block", messages: [{ stream: "stderr", text: `${F.incompleteLine(incomplete.reason)}\n` }], details: { findings: [], incomplete } };
  }
  const c = F.counts(findings);
  const lines = [...findings.map(F.findingLine), ...F.summaryLines(c)];
  const messages = lines.map((l) => ({ stream: "stdout", text: `${l}\n` }));
  return { verdict: F.verdictOf(c), messages, details: { findings, incomplete: null } };
}

function scanText(text, { file, lists }) {
  const scanner = prepareScan(lists);
  if (scanner.incomplete) return resultOf([], scanner.incomplete);
  return resultOf(scanLines(scanner, text, file), null);
}

module.exports = { scanText, prepareScan, scanLines, resultOf, splitLines, hardSecrets };

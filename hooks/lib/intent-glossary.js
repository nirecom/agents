"use strict";
// hooks/lib/intent-glossary.js — structure check for the intent.md `## Glossary`
// section (#2529): the heading must exist once, right after `## Issues`; an empty
// body passes; a non-empty body must be a `| Term | Category | Definition |` table.
// Shared by the plan-artifact hooks, bin/check-intent-glossary and bin/glossary-promote.
// Category values and their criteria are owned by rules/docs/glossary.md.

const { canonicalizeHeading } = require("./plan-schema");

const CATEGORIES = Object.freeze(["user", "internal", "session"]);
const HEADER = ["Term", "Category", "Definition"];
const FENCE_RE = /^\s*(```|~~~)/;
const H2_RE = /^##(?!#)/;
const H1_OR_H2_RE = /^#{1,2}(?!#)/;

function splitRow(line) {
  const inner = line.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "");
  return inner.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
}

function stripComments(lines) {
  let inComment = false;
  return lines.map((l) => {
    let out = "";
    let rest = l;
    while (rest.length > 0) {
      if (inComment) {
        const end = rest.indexOf("-->");
        if (end === -1) { rest = ""; break; }
        rest = rest.slice(end + 3);
        inComment = false;
      } else {
        const start = rest.indexOf("<!--");
        if (start === -1) { out += rest; break; }
        out += rest.slice(0, start);
        rest = rest.slice(start + 4);
        inComment = true;
      }
    }
    return out;
  });
}

function parseIntentGlossary(text) {
  const lines = typeof text === "string" ? text.split(/\r?\n/) : [];
  const result = { glossaryLines: [], issuesLine: null, h2: [], rows: [], body: [], table: [], stray: [] };
  let inFence = false;
  let start = null;
  let end = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (FENCE_RE.test(lines[i])) { inFence = !inFence; continue; }
    if (inFence) continue;
    if (start !== null && end === lines.length && H1_OR_H2_RE.test(lines[i])) end = i;
    if (!H2_RE.test(lines[i])) continue;
    const name = canonicalizeHeading(lines[i]);
    result.h2.push({ text: lines[i].trim(), lineNumber: i + 1 });
    if (name === "Issues" && result.issuesLine === null) result.issuesLine = i + 1;
    if (name === "Glossary") {
      result.glossaryLines.push(i + 1);
      if (start === null) start = i + 1;
    }
  }
  if (start === null) return result;
  const stripped = stripComments(lines.slice(start, end));
  stripped.forEach((l, k) => {
    if (l.trim() !== "") result.body.push({ lineNumber: start + k + 1, text: l });
  });
  const table = result.body.filter((b) => b.text.trim().startsWith("|"));
  table.slice(2).forEach((b) => {
    const cells = splitRow(b.text);
    result.rows.push({
      term: cells[0] || "",
      category: cells[1] || "",
      definition: cells.slice(2).join(" | "),
      cellCount: cells.length,
      lineNumber: b.lineNumber,
    });
  });
  result.table = table;
  if (table.length > 0) {
    result.stray = result.body.filter((b) => !b.text.trim().startsWith("|"));
  }
  return result;
}

function violation(lineNumber, line, reason) {
  return { lineNumber, line, reason };
}

function checkTable(p) {
  const out = [];
  const [header, sep] = p.table;
  const headerCells = splitRow(header.text);
  if (headerCells.length !== 3 || headerCells.some((c, i) => c !== HEADER[i])) {
    out.push(violation(header.lineNumber, header.text, "Glossary table header must be | Term | Category | Definition |"));
  }
  if (!sep || !splitRow(sep.text).every((c) => /^:?-+:?$/.test(c))) {
    const at = sep || header;
    out.push(violation(at.lineNumber, at.text, "Glossary table needs a |---|---|---| separator row after the header"));
  } else if (splitRow(sep.text).length !== HEADER.length) {
    out.push(violation(sep.lineNumber, sep.text, "Glossary table separator row must have exactly 3 cells"));
  }
  for (const s of p.stray) {
    out.push(violation(s.lineNumber, s.text, "Glossary body must hold only the table; remove this line"));
  }
  const seen = new Set();
  for (const r of p.rows) {
    const raw = p.body.find((b) => b.lineNumber === r.lineNumber).text;
    if (r.cellCount !== 3) { out.push(violation(r.lineNumber, raw, "Glossary row must have exactly 3 cells")); continue; }
    if (r.term === "") out.push(violation(r.lineNumber, raw, "Glossary row has an empty Term"));
    if (r.definition === "") out.push(violation(r.lineNumber, raw, "Glossary row has an empty Definition"));
    if (r.category === "") out.push(violation(r.lineNumber, raw, "Glossary row has an empty Category"));
    else if (!CATEGORIES.includes(r.category)) {
      out.push(violation(r.lineNumber, raw, "Category must be one of " + CATEGORIES.join(" / ") + " (got '" + r.category + "')"));
    }
    const key = r.term.toLowerCase();
    if (r.term !== "" && seen.has(key)) out.push(violation(r.lineNumber, raw, "duplicate Term '" + r.term + "'"));
    seen.add(key);
  }
  return out;
}

function checkIntentGlossary(text) {
  const p = parseIntentGlossary(text);
  if (p.glossaryLines.length === 0) {
    const msg = "`## Glossary` missing: add it right after `## Issues` (may be empty)";
    return [violation(1, msg, msg)];
  }
  if (p.glossaryLines.length > 1) {
    const at = p.glossaryLines[1];
    return [violation(at, "## Glossary", "`## Glossary` appears more than once; keep exactly one right after `## Issues`")];
  }
  const out = [];
  const g = p.glossaryLines[0];
  if (p.issuesLine !== null && g < p.issuesLine) {
    out.push(violation(g, "## Glossary", "`## Glossary` must come after `## Issues`"));
  } else if (p.issuesLine !== null) {
    const k = p.h2.findIndex((h) => h.lineNumber === p.issuesLine);
    const next = p.h2[k + 1];
    if (next && next.lineNumber !== g) {
      out.push(violation(g, "## Glossary", "`## Glossary` must come right after `## Issues` (found `" + next.text + "` between them)"));
    }
  }
  if (p.body.length === 0) return out;
  // Prose without a table is rejected: glossary promotion can only parse the table.
  if (p.table.length === 0) {
    const b = p.body[0];
    out.push(violation(b.lineNumber, b.text, "Glossary body must be empty or a | Term | Category | Definition | table"));
    return out;
  }
  return out.concat(checkTable(p));
}

module.exports = { CATEGORIES, parseIntentGlossary, checkIntentGlossary };

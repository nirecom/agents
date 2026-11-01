"use strict";
// hooks/lib/intent-glossary.js — structure check for the intent.md `## Glossary`
// section (#2529): the heading must exist once, right after `## Issues`; an empty
// body passes; a non-empty body must be a `| Term | Category | Operation | Definition |
// Identifier | Homographs |` table (V3, #2763), or a legacy V2 table without the two field
// columns, or the V1 `| Term | Category | Definition |` table that reads every row as add.
// Shared by the plan-artifact hooks, bin/check-intent-glossary and bin/glossary-promote.
// Category values and their criteria are owned by rules/docs/glossary.md.

const CATEGORIES = Object.freeze(["user", "internal", "session"]);
const OPERATIONS = Object.freeze(["add", "delete", "redefine"]);
const HEADER_V1 = ["Term", "Category", "Definition"];
const HEADER_V2 = ["Term", "Category", "Operation", "Definition"];
// V3 (#2763): the optional spelling fields, each a backticked list or empty.
const HEADER_V3 = ["Term", "Category", "Operation", "Definition", "Identifier", "Homographs"];
const HEADER_TEXT = "| Term | Category | Operation | Definition | Identifier | Homographs |";
const { fenceStep } = require("./markdown-fence");
const {
  unsafeTermChars, describeTermChars, parseSpellingList, checkIdentifierSpelling, checkHomographSpelling,
} = require("./glossary-term");
const FIELD_CELLS = [
  { name: "identifiers", label: "Identifier", cell: 4, check: checkIdentifierSpelling },
  { name: "homographs", label: "Homographs", cell: 5, check: checkHomographSpelling },
];

const H2_RE = /^##(?!#)/;
const H1_OR_H2_RE = /^#{1,2}(?!#)/;
// Exact literals only: no localized alias, case variant, suffix or missing space.
const SECTION_RE = /^## (Issues|Glossary)\s*$/;

function splitRow(line) {
  const inner = line.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "");
  return inner.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
}

function sameCells(cells, header) {
  return cells.length === header.length && cells.every((c, i) => c === header[i]);
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

// The field arrays of a V3 row; a malformed cell reads as [] and is kept in fieldErrors.
function fieldsOfCells(cells) {
  const out = {};
  const errors = [];
  for (const f of FIELD_CELLS) {
    const list = parseSpellingList(cells[f.cell] || "");
    if (Array.isArray(list)) out[f.name] = list;
    else { out[f.name] = []; errors.push(f.label + ": " + list.error); }
  }
  if (errors.length > 0) out.fieldErrors = errors;
  return out;
}

function parseIntentGlossary(text) {
  const lines = typeof text === "string" ? text.split(/\r?\n/) : [];
  const result = { glossaryLines: [], issuesLine: null, h2: [], rows: [], body: [], table: [], stray: [] };
  let fence = null;
  let start = null;
  let end = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const step = fenceStep(lines[i], fence);
    const inside = fence !== null || step.marker;
    fence = step.fence;
    if (inside) continue;
    if (start !== null && end === lines.length && H1_OR_H2_RE.test(lines[i])) end = i;
    if (!H2_RE.test(lines[i])) continue;
    const m = SECTION_RE.exec(lines[i]);
    const name = m ? m[1] : null;
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
  const headerCells = table.length > 0 ? splitRow(table[0].text) : [];
  const v3 = sameCells(headerCells, HEADER_V3);
  const v2 = v3 || sameCells(headerCells, HEADER_V2);
  result.header = v3 ? HEADER_V3 : v2 ? HEADER_V2 : HEADER_V1;
  table.slice(2).forEach((b) => {
    const cells = splitRow(b.text);
    const row = {
      term: cells[0] || "",
      category: cells[1] || "",
      operation: v2 ? (cells[2] || "") : "add",
      definition: v3 ? (cells[3] || "") : cells.slice(v2 ? 3 : 2).join(" | "),
      cellCount: cells.length,
      lineNumber: b.lineNumber,
      legacy: !v2,
    };
    if (v3) Object.assign(row, fieldsOfCells(cells));
    result.rows.push(row);
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

function checkRow(r, raw, n) {
  const out = [];
  const at = (reason) => out.push(violation(r.lineNumber, raw, reason));
  if (r.cellCount !== n) { at("Glossary row must have exactly " + n + " cells"); return out; }
  if (r.term === "") at("Glossary row has an empty Term");
  const unsafe = unsafeTermChars(r.term);
  if (unsafe.length > 0) at("Glossary Term has a forbidden character (" + describeTermChars(unsafe) + "); rename the term");
  if (!OPERATIONS.includes(r.operation)) {
    at("Operation must be one of " + OPERATIONS.join(" / ") + " (got '" + r.operation + "')");
  } else if (r.operation !== "delete" && r.definition === "") at("Glossary row has an empty Definition");
  if (r.category === "") at("Glossary row has an empty Category");
  else if (!CATEGORIES.includes(r.category)) {
    at("Category must be one of " + CATEGORIES.join(" / ") + " (got '" + r.category + "')");
  } else if (r.category === "session" && r.operation !== "add" && OPERATIONS.includes(r.operation)) {
    at("a session term only takes Operation add (got '" + r.operation + "')");
  }
  if (Array.isArray(r.identifiers)) checkFieldCells(r, at);
  return out;
}

// The V3 field cells: well-formed lists, empty on a delete row, every spelling passing its check.
function checkFieldCells(r, at) {
  for (const e of r.fieldErrors || []) at("Glossary row " + e);
  if (r.operation === "delete") {
    if (FIELD_CELLS.some((f) => r[f.name].length > 0)) at("a delete row takes no Identifier / Homographs");
    return;
  }
  for (const f of FIELD_CELLS) {
    for (const s of r[f.name]) {
      const why = f.check(r.term, s);
      if (why) at("Glossary row " + f.label + ": " + why);
    }
  }
}

// A same-term same-category delete + add cannot be matched to the approved operations
// (the before/after diff folds it into one redefine), so it must be written as redefine.
// Terms compare as written: a case-only pair is a heading rename, which diffs as delete + add.
function useRedefine(p) {
  const out = [];
  const key = (r) => r.term + "\u0000" + r.category;
  const deletes = new Set(p.rows.filter((r) => r.operation === "delete").map(key));
  const adds = new Set(p.rows.filter((r) => r.operation === "add").map(key));
  for (const r of p.rows) {
    if ((r.operation !== "add" && r.operation !== "delete") || !deletes.has(key(r)) || !adds.has(key(r))) continue;
    const raw = p.body.find((b) => b.lineNumber === r.lineNumber).text;
    out.push(violation(r.lineNumber, raw, "use-redefine: '" + r.term + "' (" + r.category + ") has both delete and add rows; write one redefine row instead"));
  }
  return out;
}

function checkTable(p) {
  const out = [];
  const [header, sep] = p.table;
  const headerCells = splitRow(header.text);
  if (![HEADER_V3, HEADER_V2, HEADER_V1].some((h) => sameCells(headerCells, h))) {
    out.push(violation(header.lineNumber, header.text, "Glossary table header must be " + HEADER_TEXT + " (legacy: | Term | Category | Operation | Definition | or | Term | Category | Definition |)"));
  }
  const n = p.header.length;
  if (!sep || !splitRow(sep.text).every((c) => /^:?-+:?$/.test(c))) {
    const at = sep || header;
    out.push(violation(at.lineNumber, at.text, "Glossary table needs a |---|...| separator row after the header"));
  } else if (splitRow(sep.text).length !== n) {
    out.push(violation(sep.lineNumber, sep.text, "Glossary table separator row must have exactly " + n + " cells"));
  }
  for (const s of p.stray) {
    out.push(violation(s.lineNumber, s.text, "Glossary body must hold only the table; remove this line"));
  }
  const seen = new Set();
  for (const r of p.rows) {
    const raw = p.body.find((b) => b.lineNumber === r.lineNumber).text;
    const rowOut = checkRow(r, raw, n);
    out.push(...rowOut);
    if (r.cellCount !== n) continue;
    const key = r.term.toLowerCase() + "\u0000" + r.operation;
    if (r.term !== "" && seen.has(key)) out.push(violation(r.lineNumber, raw, "duplicate Term '" + r.term + "' with Operation '" + r.operation + "'"));
    seen.add(key);
  }
  return out.concat(useRedefine(p));
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
    out.push(violation(b.lineNumber, b.text, "Glossary body must be empty or a " + HEADER_TEXT + " table"));
    return out;
  }
  return out.concat(checkTable(p));
}

module.exports = { CATEGORIES, OPERATIONS, parseIntentGlossary, checkIntentGlossary };

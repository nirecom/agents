"use strict";
// Entry-level parse, checks and edits for one glossary entry file (#2529).
// Entry form is owned by rules/docs/glossary.md.

const { fenceStep } = require("../../../hooks/lib/markdown-fence");
const {
  unsafeTermChars, describeTermChars, parseSpellingList, checkIdentifierSpelling, checkHomographSpelling,
} = require("../../../hooks/lib/glossary-term");

// The optional spelling fields (#2763): bullet key -> entryFields key and spelling check.
const FIELDS = [
  { key: "Identifier", name: "identifiers", check: checkIdentifierSpelling },
  { key: "Homographs", name: "homographs", check: checkHomographSpelling },
];
const FIELD_KEYS = new Set(FIELDS.map((f) => f.key));

const ENTRY_RE = /^###(?!#)\s+(.*\S)\s*$/;
const H2_RE = /^##(?!#)/;
const H1_RE = /^#(?!#)\s/;
const DEEP_RE = /^####/;
const BULLET_RE = /^- \*\*([^*]+)\*\*:\s?(.*)$/;
const LINK_RE = /\[[^\]]*\]\([^)\s]+\)/g;
const MAX_DEFINITION_LINES = 2;

function compareTerms(a, b) {
  const x = String(a).toLowerCase();
  const y = String(b).toLowerCase();
  if (x === y) return 0;
  return x < y ? -1 : 1;
}

function newEntry(term, lineNumber) {
  return { term, lineNumber, bullets: [], stray: [] };
}

// Returns { entries, errors, h2 }: entries carry their bullets (with continuation
// line counts); errors are lines that cannot belong to an entry.
function parseGlossaryFile(text) {
  const lines = typeof text === "string" ? text.split(/\r?\n/) : [];
  const entries = [];
  const errors = [];
  const h2 = [];
  const h1 = [];
  const deep = [];
  let firstContentIsH1 = null;
  let cur = null;
  let lastBullet = null;
  let fence = null;
  lines.forEach((line, i) => {
    const n = i + 1;
    const step = fenceStep(line, fence);
    const wasInFence = fence !== null;
    fence = step.fence;
    if (step.marker) {
      if (firstContentIsH1 === null) firstContentIsH1 = false;
      if (cur) cur.stray.push(n); return;
    }
    if (wasInFence) return;
    if (line.trim() === "") { lastBullet = null; return; }
    if (line.trim().startsWith("<!--")) return;
    if (firstContentIsH1 === null) firstContentIsH1 = H1_RE.test(line);
    if (H1_RE.test(line)) h1.push(n);
    if (!cur && DEEP_RE.test(line)) deep.push(n);
    if (H2_RE.test(line)) { h2.push(n); return; }
    const m = ENTRY_RE.exec(line);
    if (m) { cur = newEntry(m[1], n); entries.push(cur); lastBullet = null; return; }
    if (!cur) return; // intro prose above the first entry
    const b = BULLET_RE.exec(line);
    if (b) { lastBullet = { key: b[1].trim(), value: b[2], lineNumber: n, lines: 1 }; cur.bullets.push(lastBullet); return; }
    if (lastBullet && /^\s+\S/.test(line)) { lastBullet.lines += 1; lastBullet.value += " " + line.trim(); return; }
    cur.stray.push(n);
  });
  if (fence !== null) errors.push("unclosed code fence");
  return { entries, errors, h2, h1, deep, firstContentIsH1: firstContentIsH1 === true };
}

function checkEntry(e) {
  const out = [];
  const at = "line " + e.lineNumber + ": '" + e.term + "'";
  const unsafe = unsafeTermChars(e.term);
  if (unsafe.length > 0) out.push(at + " heading has a forbidden character (" + describeTermChars(unsafe) + ")");
  const defs = e.bullets.filter((b) => b.key === "Definition");
  const rels = e.bullets.filter((b) => b.key === "Related");
  const others = e.bullets.filter((b) => b.key !== "Definition" && b.key !== "Related" && !FIELD_KEYS.has(b.key));
  out.push(...checkFields(e, at));
  if (defs.length !== 1) out.push(at + " needs exactly one '- **Definition**:' (found " + defs.length + ")");
  else if (defs[0].value.trim() === "") out.push(at + " Definition is empty");
  else if (defs[0].lines > MAX_DEFINITION_LINES) {
    out.push(at + " Definition spans " + defs[0].lines + " lines (max " + MAX_DEFINITION_LINES + ")");
  }
  if (rels.length !== 1) out.push(at + " needs exactly one '- **Related**:' (found " + rels.length + ")");
  else {
    const links = (rels[0].value.match(LINK_RE) || []).length;
    if (links !== 1) out.push(at + " Related must hold exactly one Markdown link (found " + links + ")");
  }
  for (const o of others) out.push("line " + o.lineNumber + ": '" + e.term + "' has a disallowed bullet '" + o.key + "'");
  for (const n of e.stray) out.push("line " + n + ": '" + e.term + "' has a line that is not a Definition/Identifier/Homographs/Related bullet");
  return out;
}

// The Identifier / Homographs bullets: at most one each, a non-empty backticked list, every
// spelling passing its check.
function checkFields(e, at) {
  const out = [];
  for (const f of FIELDS) {
    const bullets = e.bullets.filter((b) => b.key === f.key);
    if (bullets.length > 1) out.push(at + " has more than one '- **" + f.key + "**:' (found " + bullets.length + ")");
    for (const b of bullets) {
      const where = "line " + b.lineNumber + ": '" + e.term + "' " + f.key;
      const list = parseSpellingList(b.value);
      if (!Array.isArray(list)) { out.push(where + ": " + list.error); continue; }
      if (list.length === 0) { out.push(where + " is empty"); continue; }
      for (const s of list) {
        const why = f.check(e.term, s);
        if (why) out.push(where + ": " + why);
      }
    }
  }
  return out;
}

// entryFields(entry) -> { identifiers, homographs } of the first bullet of each ([] when absent or malformed).
function entryFields(e) {
  const out = {};
  for (const f of FIELDS) {
    const b = e.bullets.find((x) => x.key === f.key);
    const list = b ? parseSpellingList(b.value) : [];
    out[f.name] = Array.isArray(list) ? list : [];
  }
  return out;
}

function checkGlossaryFile(text) {
  const p = parseGlossaryFile(text);
  const out = p.errors.slice();
  if (!p.firstContentIsH1) out.push("line 1: the file must start with a single '# ' H1 title");
  for (const n of p.h1.slice(p.firstContentIsH1 ? 1 : 0)) out.push("line " + n + ": only one '# ' H1 is allowed");
  for (const n of p.deep) out.push("line " + n + ": '####' headings are not allowed outside an entry");
  for (const n of p.h2) out.push("line " + n + ": '##' section headings are not allowed (entries only)");
  p.entries.forEach((e, i) => {
    out.push(...checkEntry(e));
    if (i === 0) return;
    const prev = p.entries[i - 1];
    const c = compareTerms(prev.term, e.term);
    if (c > 0) out.push("line " + e.lineNumber + ": '" + e.term + "' is out of order (after '" + prev.term + "')");
    if (c === 0) out.push("line " + e.lineNumber + ": '" + e.term + "' duplicates '" + prev.term + "'");
  });
  return out;
}

function eolOf(text) {
  return text.includes("\r\n") ? "\r\n" : "\n";
}

// Insert an entry block (`### term` ... ) before the first entry that sorts after it.
function insertEntry(text, term, block) {
  const eol = eolOf(text);
  const body = block.replace(/\r?\n/g, eol).replace(/(\r?\n)+$/, "");
  const lines = text.split(/\r?\n/);
  const next = parseGlossaryFile(text).entries.find((e) => compareTerms(e.term, term) > 0);
  if (next) {
    lines.splice(next.lineNumber - 1, 0, ...body.split(eol), "");
    return lines.join(eol);
  }
  return text.replace(/(\r?\n)+$/, "") + eol + eol + body + eol;
}

function findEntry(text, term) {
  const entries = parseGlossaryFile(text).entries;
  const i = entries.findIndex((e) => compareTerms(e.term, term) === 0);
  return i === -1 ? null : { entry: entries[i], next: entries[i + 1] || null };
}

// Remove the entry block of `term` (case-insensitive); null when the term is absent.
function removeEntry(text, term) {
  const found = findEntry(text, term);
  if (!found) return null;
  const eol = eolOf(text);
  const lines = text.split(/\r?\n/);
  const start = found.entry.lineNumber - 1;
  if (found.next) {
    lines.splice(start, found.next.lineNumber - 1 - start);
    return lines.join(eol);
  }
  return lines.slice(0, start).join(eol).replace(/(\r?\n)+$/, "") + eol;
}

// Replace the Definition bullet (continuation lines included) of `term`; null when the
// term or its Definition bullet is absent. A multi-line definition is indented by 2.
function replaceDefinition(text, term, definition) {
  const found = findEntry(text, term);
  const def = found && found.entry.bullets.find((b) => b.key === "Definition");
  if (!def) return null;
  const eol = eolOf(text);
  const lines = text.split(/\r?\n/);
  const body = String(definition).split(/\r?\n/).map((l, k) => (k === 0 ? "- **Definition**: " + l : "  " + l));
  lines.splice(def.lineNumber - 1, def.lines, ...body);
  return lines.join(eol);
}

// fieldLines(fields) -> the Identifier / Homographs bullet lines of the non-empty fields.
function fieldLines(fields) {
  const f = fields || {};
  return FIELDS.filter((x) => Array.isArray(f[x.name]) && f[x.name].length > 0)
    .map((x) => "- **" + x.key + "**: " + f[x.name].map((s) => "`" + s + "`").join(", "));
}

// Replace the Identifier / Homographs bullets of `term` with `fields`, placed right after the
// Definition bullet; an empty field removes its bullet. null when the term or its Definition is absent.
function replaceFields(text, term, fields) {
  const found = findEntry(text, term);
  const def = found && found.entry.bullets.find((b) => b.key === "Definition");
  if (!def) return null;
  const drop = new Set();
  for (const b of found.entry.bullets.filter((x) => FIELD_KEYS.has(x.key))) {
    for (let k = 0; k < b.lines; k++) drop.add(b.lineNumber - 1 + k);
  }
  const defEnd = def.lineNumber - 1 + def.lines - 1;
  const out = [];
  text.split(/\r?\n/).forEach((line, i) => {
    if (!drop.has(i)) out.push(line);
    if (i === defEnd) out.push(...fieldLines(fields));
  });
  return out.join(eolOf(text));
}

module.exports = {
  compareTerms,
  parseGlossaryFile,
  checkGlossaryFile,
  insertEntry,
  removeEntry,
  replaceDefinition,
  entryFields,
  fieldLines,
  replaceFields,
};

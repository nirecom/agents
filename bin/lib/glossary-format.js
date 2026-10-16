#!/usr/bin/env node
"use strict";
// bin/lib/glossary-format.js — parser and checks for the glossary entry files
// docs/glossary-user*.md / docs/glossary-internal*.md (#2529). Shared by the
// bin/review-doc-glossary gate, bin/glossary-promote and the codex prompt data
// (bin/lib/codex-glossary.sh via `prompt-data`) so the order, range and routing
// decisions are made by one set of functions. Entry form and the range split rule
// are owned by rules/docs/glossary.md.

const fs = require("fs");
const path = require("path");

const NAME_RE = /^glossary-(user|internal)(?:-([a-z])-([a-z]))?\.md$/;
const CANDIDATE_RE = /^glossary-(user|internal)(?:-[^/\\]*)?\.md$/;
const FENCE_RE = /^\s*(```|~~~)/;
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
  let inFence = false;
  lines.forEach((line, i) => {
    const n = i + 1;
    if (FENCE_RE.test(line)) {
      if (firstContentIsH1 === null) firstContentIsH1 = false;
      inFence = !inFence; if (cur) cur.stray.push(n); return;
    }
    if (inFence) return;
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
  if (inFence) errors.push("unclosed code fence");
  return { entries, errors, h2, h1, deep, firstContentIsH1: firstContentIsH1 === true };
}

function checkEntry(e) {
  const out = [];
  const at = "line " + e.lineNumber + ": '" + e.term + "'";
  const defs = e.bullets.filter((b) => b.key === "Definition");
  const rels = e.bullets.filter((b) => b.key === "Related");
  const others = e.bullets.filter((b) => b.key !== "Definition" && b.key !== "Related");
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
  for (const n of e.stray) out.push("line " + n + ": '" + e.term + "' has a line that is not a Definition/Related bullet");
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

function parseGlossaryPath(p) {
  const m = NAME_RE.exec(path.basename(String(p)));
  if (!m) return null;
  if (m[2] === undefined) return { category: m[1], range: null };
  if (m[2] > m[3]) return null;
  return { category: m[1], range: { from: m[2], to: m[3] } };
}

// True for any name that claims to be a user/internal glossary file, parseable or not.
function isGlossaryCandidate(p) {
  return CANDIDATE_RE.test(path.basename(String(p)));
}

function termBucket(term) {
  const c = String(term).toLowerCase().charAt(0);
  return c >= "a" && c <= "z" ? c : "a";
}

function checkRangeMembership(p, entries) {
  const parsed = parseGlossaryPath(p);
  if (!parsed || !parsed.range) return [];
  const { from, to } = parsed.range;
  return entries
    .filter((e) => { const b = termBucket(e.term); return b < from || b > to; })
    .map((e) => p + ": '" + e.term + "' is outside the file's range " + from + "-" + to);
}

function nextLetter(c) {
  return String.fromCharCode(c.charCodeAt(0) + 1);
}

function checkCategorySet(category, files) {
  const out = [];
  const unsplit = files.filter((f) => f.range === null);
  const ranged = files.filter((f) => f.range !== null).sort((a, b) => (a.range.from < b.range.from ? -1 : 1));
  if (unsplit.length > 0 && ranged.length > 0) {
    out.push(category + ": " + unsplit[0].path + " coexists with range-split files");
  }
  if (ranged.length === 0) return out;
  let expect = "a";
  for (const f of ranged) {
    const { from, to } = f.range;
    if (expect !== null && from > expect) out.push(category + ": letters " + expect + "-" + String.fromCharCode(from.charCodeAt(0) - 1) + " are not covered (gap before " + f.path + ")");
    if (expect === null || from < expect) out.push(category + ": " + f.path + " overlaps an earlier range");
    expect = to === "z" ? null : nextLetter(to);
  }
  if (expect !== null) out.push(category + ": letters " + expect + "-z are not covered");
  return out;
}

function checkFileSet(paths) {
  const out = [];
  const groups = new Map();
  for (const p of paths) {
    const parsed = parseGlossaryPath(p);
    if (!parsed) { out.push(p + ": unparseable glossary file name (use glossary-<category>.md or glossary-<category>-<from>-<to>.md)"); continue; }
    if (!groups.has(parsed.category)) groups.set(parsed.category, []);
    groups.get(parsed.category).push({ path: p, range: parsed.range });
  }
  for (const [category, files] of groups) out.push(...checkCategorySet(category, files));
  return out;
}

function fileForTerm(paths, category, term) {
  const bucket = termBucket(term);
  for (const p of paths) {
    const parsed = parseGlossaryPath(p);
    if (!parsed || parsed.category !== category) continue;
    if (parsed.range === null || (bucket >= parsed.range.from && bucket <= parsed.range.to)) return p;
  }
  return null;
}

// Insert an entry block (`### term` ... ) before the first entry that sorts after it.
function insertEntry(text, term, block) {
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const body = block.replace(/\r?\n/g, eol).replace(/(\r?\n)+$/, "");
  const lines = text.split(/\r?\n/);
  const next = parseGlossaryFile(text).entries.find((e) => compareTerms(e.term, term) > 0);
  if (next) {
    lines.splice(next.lineNumber - 1, 0, ...body.split(eol), "");
    return lines.join(eol);
  }
  return text.replace(/(\r?\n)+$/, "") + eol + eol + body + eol;
}

// check-files <label> <path> [<label> <path> ...]: per-file form, name and range
// checks plus the cross-file duplicate and file-set checks. BLOCK lines on stdout.
function checkFiles(pairs) {
  const blocks = [];
  const seen = new Map();
  for (const { label, file } of pairs) {
    const text = fs.readFileSync(file, "utf8");
    for (const r of checkGlossaryFile(text)) blocks.push(label + ": " + r);
    const entries = parseGlossaryFile(text).entries;
    blocks.push(...checkRangeMembership(label, entries));
    for (const e of entries) {
      const key = e.term.toLowerCase();
      if (seen.has(key) && seen.get(key) !== label) blocks.push("term '" + e.term + "' is defined in both " + seen.get(key) + " and " + label);
      else seen.set(key, label);
    }
  }
  blocks.push(...checkFileSet(pairs.map((p) => p.label)));
  return blocks;
}

// Neutralizes bracketed prompt delimiters ([X START] / [X END]) and HTML comment fences.
function neutralize(s) {
  return s
    .replace(/\[([A-Z][A-Z ]*) (START|END)\]/g, "($1 $2)")
    .replace(/<!--/g, "(!--")
    .replace(/-->/g, "--)");
}

// The `### term` line plus the Definition bullet as written (continuation lines kept).
function promptEntryLines(lines, e) {
  const out = [neutralize(lines[e.lineNumber - 1])];
  const def = e.bullets.find((b) => b.key === "Definition");
  if (def) {
    for (let k = 0; k < def.lines; k++) out.push(neutralize(lines[def.lineNumber - 1 + k]));
  }
  return out;
}

// prompt-data: whole entries under each file's label until a cap would be crossed;
// every entry left out is counted in the trailing [TRUNCATED: <n> entries omitted] line.
function promptData(pairs, maxLines, maxBytes) {
  let out = "";
  let usedLines = 0;
  let usedBytes = 0;
  let omitted = 0;
  for (const { label, file } of pairs) {
    let text;
    try { text = fs.readFileSync(file, "utf8"); } catch (e) {
      if (e.code === "ENOENT") continue;
      throw e;
    }
    const lines = text.split(/\r?\n/);
    let head = neutralize(label) + "\n";
    for (const e of parseGlossaryFile(text).entries) {
      const chunk = head + promptEntryLines(lines, e).join("\n") + "\n";
      const n = chunk.split("\n").length - 1;
      const b = Buffer.byteLength(chunk, "utf8");
      if (omitted > 0 || usedLines + n > maxLines || usedBytes + b > maxBytes) {
        omitted++;
        continue;
      }
      out += chunk;
      usedLines += n;
      usedBytes += b;
      head = "";
    }
  }
  if (omitted > 0) out += "[TRUNCATED: " + omitted + " entries omitted]\n";
  return out;
}

const LIMIT_FLAGS = { "--max-lines": "maxLines", "--max-bytes": "maxBytes" };

function parsePromptDataArgs(rest) {
  const limits = { maxLines: Infinity, maxBytes: Infinity };
  let i = 0;
  while (i < rest.length && Object.prototype.hasOwnProperty.call(LIMIT_FLAGS, rest[i])) {
    const value = rest[i + 1];
    if (value === undefined || !/^[1-9][0-9]*$/.test(value)) return null;
    limits[LIMIT_FLAGS[rest[i]]] = Number(value);
    i += 2;
  }
  const tail = rest.slice(i);
  if (tail.length === 0 || tail.length % 2 !== 0) return null;
  const pairs = [];
  for (let k = 0; k < tail.length; k += 2) pairs.push({ label: tail[k], file: tail[k + 1] });
  return { limits, pairs };
}

function mainPromptData(rest) {
  const parsed = parsePromptDataArgs(rest);
  if (!parsed) {
    process.stderr.write("usage: glossary-format.js prompt-data [--max-lines N] [--max-bytes N] <label> <path> [<label> <path> ...]\n");
    return 2;
  }
  try {
    process.stdout.write(promptData(parsed.pairs, parsed.limits.maxLines, parsed.limits.maxBytes));
  } catch (e) {
    process.stderr.write("glossary-format.js: " + e.message + "\n");
    return 2;
  }
  return 0;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === "prompt-data") return mainPromptData(rest);
  if (cmd !== "check-files" || rest.length === 0 || rest.length % 2 !== 0) {
    process.stderr.write("usage: glossary-format.js check-files <label> <path> [<label> <path> ...]\n");
    return 2;
  }
  const pairs = [];
  for (let i = 0; i < rest.length; i += 2) pairs.push({ label: rest[i], file: rest[i + 1] });
  let blocks;
  try { blocks = checkFiles(pairs); } catch (e) {
    process.stderr.write("glossary-format.js: " + e.message + "\n");
    return 2;
  }
  for (const b of blocks) process.stdout.write("  BLOCK: " + b + "\n");
  return blocks.length === 0 ? 0 : 1;
}

// exitCode, not exit(): a forced exit can cut off stdout still draining into a pipe.
if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = {
  compareTerms,
  parseGlossaryFile,
  checkGlossaryFile,
  parseGlossaryPath,
  isGlossaryCandidate,
  termBucket,
  checkRangeMembership,
  checkFileSet,
  fileForTerm,
  insertEntry,
  checkFiles,
};

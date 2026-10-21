"use strict";
// bin/lib/glossary-drift.js — the deterministic spelling-drift check of #2529 S3. Owns the
// excluded contexts (extractCheckableText) and the variant match (findVariants); it never reads
// a file: the artifact text and the terms come from scope.js loadStageInputs (invariant I-FP).
// Its source is one of the RULE_MODULES of the glossary-check fingerprint.

const { normalizeTerm } = require("../../hooks/lib/glossary-term");
const { classifyLines } = require("../../hooks/lib/comment-block-scan");
const { fenceStep } = require("../../hooks/lib/markdown-fence");

const BOUNDARY_RE = /[A-Za-z0-9_-]/;
const SEPARATOR_RE = /^(?:[ \t]+|-)$/;
const WORD_RE = /[A-Za-z0-9_]+/g;
const ASCII_NORM_RE = /^[a-z0-9]+(?: [a-z0-9]+)*$/;
// Sentence start: line head (after a list / heading / quote marker), or after `. ` / `: `;
// emphasis markers in between are transparent (`**Title:** Word`).
const SENTENCE_HEAD_RE = /^\s*(?:(?:[-*+]|\d+[.)])\s+|#{1,6}\s+|>\s*)?[*_]*$|[.!?:][*_]*\s+[*_]*$/;
const EDGE_PUNCT_RE = /^["'([{<]+|["')\]}>,;:!?.]+$/g;
const PATH_EXT_RE = /[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]{0,7}$/;

const spaces = (s) => " ".repeat(s.length);
const blankAll = (s, re) => s.replace(re, spaces);

const CODE_SPAN_RE = /(`+)[^`]*?\1/g;

// Blanks <!-- ... --> (possibly multi-line); returns [line, stillInComment]. Outside a comment an
// opener inside an inline code span is literal text (it is looked up with the spans blanked);
// inside one, backticks are comment text and only `-->` closes it.
function blankComments(line, inComment) {
  let out = "";
  let rest = line;
  let open = inComment;
  while (rest.length > 0) {
    const at = open ? rest.indexOf("-->") : blankAll(rest, CODE_SPAN_RE).indexOf("<!--");
    if (at === -1) { out += open ? spaces(rest) : rest; rest = ""; break; }
    const cut = at + (open ? 3 : 0);
    out += open ? spaces(rest.slice(0, cut)) : rest.slice(0, cut);
    rest = rest.slice(cut);
    if (!open) { out += spaces(rest.slice(0, 4)); rest = rest.slice(4); }
    open = !open;
  }
  return [out, open];
}

function isPathShaped(token) {
  const core = token.replace(EDGE_PUNCT_RE, "");
  return core.includes("/") || core.includes("\\") || PATH_EXT_RE.test(core);
}

function blankInline(line) {
  let s = blankAll(line, /(`+)[^`]*?\1/g);
  s = blankAll(s, /<<.*?>>/g);
  s = s.replace(/\]\([^)]*\)/g, (m) => "]" + spaces(m.slice(1)));
  s = blankAll(s, /<[A-Za-z][A-Za-z0-9+.-]*:[^>\s]*>/g);
  return s.replace(/\S+/g, (t) => (isPathShaped(t) ? spaces(t) : t));
}

function markdownPass(lines) {
  const out = lines.slice();
  let start = 0;
  if (out.length > 0 && out[0].trim() === "---") {
    const end = out.findIndex((l, i) => i > 0 && (l.trim() === "---" || l.trim() === "..."));
    if (end !== -1) {
      for (let i = 0; i <= end; i++) out[i] = spaces(out[i]);
      start = end + 1;
    }
  }
  let fence = null;
  let inComment = false;
  for (let i = start; i < out.length; i++) {
    const step = inComment ? { fence, marker: false } : fenceStep(out[i], fence);
    const inside = fence !== null || step.marker;
    fence = step.fence;
    if (inside) { out[i] = spaces(out[i]); continue; }
    const [line, open] = blankComments(out[i], inComment);
    inComment = open;
    out[i] = blankInline(line);
  }
  return out;
}

// Keeps only the comment body of a code file: the marker becomes blanks, code lines go blank.
function commentLines(text, lines) {
  const kinds = new Map(classifyLines(text).map((c) => [c.lineNo, c.kind]));
  return lines.map((l, i) => {
    if (kinds.get(i + 1) !== "comment") return spaces(l);
    const body = l.replace(/^(\s*)(\/\*+|\*\/|\/\/+|#+|\*)/, (m) => spaces(m));
    return body.replace(/\*\/\s*$/, (m) => spaces(m));
  });
}

// extractCheckableText(text, format) -> the text with every excluded context blanked; the line
// count and the columns are preserved. format: "markdown" | "code".
function extractCheckableText(text, format) {
  const src = typeof text === "string" ? text.replace(/^﻿/, "") : "";
  const lines = src.split("\n").map((l) => l.replace(/\r$/, ""));
  const base = format === "code" ? commentLines(src, lines) : lines;
  return markdownPass(base).join("\n");
}

function wordsOf(line) {
  const words = [];
  let m;
  WORD_RE.lastIndex = 0;
  while ((m = WORD_RE.exec(line)) !== null) words.push({ start: m.index, end: m.index + m[0].length, text: m[0] });
  return words;
}

// The match key: the normalized form with the word separators stripped, so a split (`work-flow`)
// or a merge (`glossarydrift`) of a term meets the same key whatever its word count.
const compactKey = (s) => normalizeTerm(s).replace(/ /g, "");
// An identifier term (one with `_`, e.g. WORKFLOW_PLANS_DIR) folds `_` like `-` and keeps its last
// word unsingularized: AGENTS_NOTE and AGENTS_NOTES may name two identifiers.
const identKey = (s) => s.toLowerCase().replace(/[-_\s]+/g, "");
const identWords = (s) => s.toLowerCase().split(/[-_\s]+/);
// camelCase / PascalCase (`workflowPlansDir`) may name the identifier in another language.
const CAMEL_RE = /[a-z][A-Z]/;
// Singularization shortens the last word by at most this many characters ("ies" -> "y").
const SINGULAR_SLACK = 2;

// The separators of a spelling as "offset:char" entries (offset in letters, whitespace -> " ").
function separatorsOf(s) {
  const out = new Set();
  let at = 0;
  for (const ch of s) {
    if (/[-_\s]/.test(ch)) out.add(`${at}:${/\s/.test(ch) ? " " : ch}`);
    else at += 1;
  }
  return out;
}

// key -> { spellings:Set, candidates:[{ term, boundaries:Set, seps:Set }] } per ASCII term, plain
// and identifier terms in separate maps; boundaries are the key offsets of the term's word breaks.
// Terms sharing a key (`workflow`, `work flow`) are all kept, sorted, for lookup to choose from.
function indexTerms(terms) {
  const exact = new Set();
  const plain = new Map();
  const ident = new Map();
  let maxLen = 0;
  for (const t of terms || []) {
    const term = String(t == null ? "" : t).trim();
    if (term === "" || exact.has(term)) continue;
    exact.add(term);
    const isIdent = term.includes("_");
    const parts = isIdent ? identWords(term) : normalizeTerm(term).split(" ");
    if (isIdent ? !parts.every((w) => /^[a-z0-9]+$/.test(w)) : !ASCII_NORM_RE.test(parts.join(" "))) continue;
    const key = isIdent ? identKey(term) : compactKey(term);
    const map = isIdent ? ident : plain;
    maxLen = Math.max(maxLen, key.length);
    if (!map.has(key)) map.set(key, { spellings: new Set(), candidates: [] });
    const entry = map.get(key);
    entry.spellings.add(term);
    const boundaries = new Set();
    let at = 0;
    for (const w of parts.slice(0, -1)) { at += w.length; boundaries.add(at); }
    entry.candidates.push({ term, boundaries, seps: separatorsOf(term) });
  }
  for (const map of [plain, ident]) {
    for (const e of map.values()) e.candidates.sort((a, b) => (a.term < b.term ? -1 : a.term > b.term ? 1 : 0));
  }
  return { exact, plain, ident, maxLen };
}

// The candidate whose separators differ least from the variant's; ties keep the sorted order.
function closest(candidates, seq) {
  const seps = separatorsOf(seq);
  const dist = (c) => [...c.seps].filter((s) => !seps.has(s)).length + [...seps].filter((s) => !c.seps.has(s)).length;
  return candidates.reduce((best, c) => (dist(c) < dist(best) ? c : best));
}

// -> { seq, breaks, ident } — breaks are the key offsets of the whitespace separators (a hyphen
// break may fall anywhere, a whitespace break only where the term has a word break).
function windowAt(line, words, i, n) {
  const last = words[i + n - 1];
  if (!last) return null;
  const breaks = [];
  let at = 0;
  for (let k = i; k < i + n; k++) {
    if (k > i) {
      const sep = line.slice(words[k - 1].end, words[k].start);
      if (!SEPARATOR_RE.test(sep)) return null;
      if (sep !== "-") breaks.push(at);
    }
    at += words[k].text.replace(/_/g, "").length;
  }
  const before = words[i].start > 0 ? line.charAt(words[i].start - 1) : "";
  const after = line.charAt(last.end);
  if ((before && BOUNDARY_RE.test(before)) || (after && BOUNDARY_RE.test(after))) return null;
  const seq = line.slice(words[i].start, last.end);
  return { seq, breaks, ident: seq.includes("_") };
}

// A window with `_` can only be an identifier term's variant; one without may be either.
// -> { term, spellings } — the term is chosen among those whose word breaks admit the window's.
function lookup(index, w) {
  const tries = w.ident ? [[index.ident, identKey]] : [[index.plain, compactKey], [index.ident, identKey]];
  for (const [map, keyOf] of tries) {
    const entry = map.get(keyOf(w.seq));
    if (!entry || (map === index.ident && CAMEL_RE.test(w.seq))) continue;
    const fits = entry.candidates.filter((c) => w.breaks.every((b) => c.boundaries.has(b)));
    if (fits.length === 0) continue;
    return { term: closest(fits, w.seq).term, spellings: entry.spellings };
  }
  return null;
}

// The sentence-start exception: the only difference from a spelling is the capital first letter.
function sentenceStartCase(line, start, seq, spellings) {
  if (!SENTENCE_HEAD_RE.test(line.slice(0, start))) return false;
  const lowered = seq.charAt(0).toLowerCase() + seq.slice(1);
  return lowered !== seq && spellings.has(lowered);
}

// findVariants(text, terms) -> [{ term, variant, line }] — a word sequence of any word count whose
// separator-stripped key equals a term's but whose spelling matches no term exactly.
// Non-ASCII terms match exactly only.
function findVariants(text, terms) {
  const index = indexTerms(terms);
  const out = [];
  String(text == null ? "" : text).split("\n").forEach((line, idx) => {
    const words = wordsOf(line);
    for (let i = 0; i < words.length; i++) {
      let chars = 0;
      for (let n = 1; i + n <= words.length; n++) {
        chars += words[i + n - 1].text.replace(/_/g, "").length;
        if (chars > index.maxLen + SINGULAR_SLACK) break;
        const w = windowAt(line, words, i, n);
        if (w === null || index.exact.has(w.seq)) continue;
        const hit = lookup(index, w);
        if (!hit || sentenceStartCase(line, words[i].start, w.seq, hit.spellings)) continue;
        out.push({ term: hit.term, variant: w.seq, line: idx + 1 });
      }
    }
  });
  return out;
}

// scanStageInputs(inputs) -> [{ term, norm, variant, path, line, where }] over the artifact files
// of one loadStageInputs result; a file's lineMap maps a range line back to its file line. A
// term an intent row deletes is no canonical term, even while the glossary file still lists it;
// an add / redefine row of the same term (a category move) keeps it. A delete row matches its own
// spelling only (case-insensitive), so deleting "workflows" leaves a distinct "workflow" heading.
const spellingKey = (s) => String(s == null ? "" : s).trim().toLowerCase();
function scanStageInputs(inputs) {
  const rows = (inputs && inputs.intentRows && inputs.intentRows.rows) || [];
  const kept = rows.filter((r) => r.operation !== "delete");
  const keptKeys = new Set(kept.map((r) => spellingKey(r.term)));
  const deleted = new Set(rows.filter((r) => r.operation === "delete").map((r) => spellingKey(r.term))
    .filter((k) => !keptKeys.has(k)));
  const terms = [...((inputs && inputs.glossary && inputs.glossary.terms) || [])]
    .concat(kept.map((r) => r.term))
    .filter((t) => !deleted.has(spellingKey(t)));
  const hits = [];
  for (const file of (inputs && inputs.artifact && inputs.artifact.files) || []) {
    if (typeof file.text !== "string" || file.text === "") continue;
    for (const v of findVariants(extractCheckableText(file.text, file.kind), terms)) {
      const line = Array.isArray(file.lineMap) && file.lineMap[v.line - 1] ? file.lineMap[v.line - 1] : v.line;
      hits.push({ term: v.term, norm: normalizeTerm(v.term), variant: v.variant, path: file.path, line, where: `${file.path}:${line}` });
    }
  }
  return hits;
}

module.exports = { extractCheckableText, findVariants, scanStageInputs };
